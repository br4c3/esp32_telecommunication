import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'firebase_options.dart';
import 'firebase_web_registration.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    registerFirebaseWebPlugins();
    runApp(const FirebaseBootstrap());
    return;
  }
  runApp(const Esp32App());
}

class FirebaseBootstrap extends StatefulWidget {
  const FirebaseBootstrap({super.key});

  @override
  State<FirebaseBootstrap> createState() => _FirebaseBootstrapState();
}

class _FirebaseBootstrapState extends State<FirebaseBootstrap> {
  late final Future<FirebaseApp> _initialization = Firebase.initializeApp(
    options: DefaultFirebaseOptions.web,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<FirebaseApp>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Firebase 연결에 실패했습니다. 잠시 후 새로고침해 주세요.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      }
      return const Esp32App();
    },
  );
}

enum CalibrationStatus {
  checking,
  zeroRequired,
  zeroCalibrating,
  zeroWarning,
  balanceRequired,
  balanceCalibrating,
  balanceWarning,
  ready,
}

abstract final class AppColors {
  static const corporateYellow = Color(0xffffc928);
  static const ink = Color(0xff202427);
  static const canvas = Color(0xffe7e7e1);
  static const surface = Color(0xfff1f1ec);
}

String bluetoothErrorMessage(Object error, {required String fallback}) {
  final message = error.toString().toLowerCase();
  if (error is TimeoutException || message.contains('timeout')) {
    return '시간 안에 ESP32를 찾지 못했습니다. 전원과 거리를 확인한 뒤 다시 시도해 주세요.';
  }
  if (message.contains('notfounderror') ||
      message.contains('cancelled') ||
      message.contains('canceled') ||
      message.contains('user cancelled')) {
    return 'Bluetooth 기기 선택이 취소되었습니다.';
  }
  if (message.contains('user gesture')) {
    return 'Bluetooth 검색 버튼을 직접 눌러 기기를 선택해 주세요.';
  }
  if (message.contains('notallowederror') ||
      message.contains('permission') ||
      message.contains('securityerror')) {
    return 'Bluetooth 권한이 거부되었습니다. 브라우저 설정에서 권한을 허용해 주세요.';
  }
  if (message.contains('not supported') ||
      message.contains('unsupported') ||
      message.contains('webbluetooth') ||
      message.contains('web bluetooth')) {
    return '이 브라우저에서는 Bluetooth 검색을 지원하지 않습니다. Chrome 또는 Edge에서 다시 시도해 주세요.';
  }
  if (message.contains('networkerror') ||
      message.contains('gatt') ||
      message.contains('failed to connect')) {
    return 'ESP32와 Bluetooth 연결을 완료하지 못했습니다. 다른 앱의 연결을 끊고 ESP32 전원을 다시 켠 뒤 시도해 주세요.';
  }
  if (message.contains('통신 서비스를 찾을 수 없습니다') ||
      message.contains('송수신 채널을 찾을 수 없습니다')) {
    return 'ESP32 통신 채널을 찾지 못했습니다. Seat Care 펌웨어가 설치되어 있는지 확인해 주세요.';
  }
  return fallback;
}

String scannerErrorMessage(MobileScannerException error) =>
    switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        '카메라 권한이 거부되었습니다. 브라우저 설정에서 카메라를 허용해 주세요.',
      MobileScannerErrorCode.unsupported => '이 기기에서는 카메라 스캔을 지원하지 않습니다.',
      MobileScannerErrorCode.controllerAlreadyInitialized ||
      MobileScannerErrorCode.controllerInitializing =>
        '카메라를 준비하고 있습니다. 잠시 후 다시 시도해 주세요.',
      _ => '카메라를 시작할 수 없습니다. 권한과 카메라 상태를 확인해 주세요.',
    };

class Esp32App extends StatelessWidget {
  const Esp32App({super.key, this.requestBluetoothOnLaunch = true});

  final bool requestBluetoothOnLaunch;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32 Terminal',
      theme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: AppColors.corporateYellow,
              brightness: Brightness.light,
              surface: AppColors.surface,
            ).copyWith(
              primary: AppColors.corporateYellow,
              onPrimary: AppColors.ink,
              secondary: AppColors.ink,
              onSecondary: Colors.white,
            ),
        scaffoldBackgroundColor: AppColors.canvas,
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xfff4f4ef),
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: const BorderSide(color: Color(0xffa9aaa5)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: false,
          backgroundColor: AppColors.ink,
          foregroundColor: Colors.white,
          shape: Border(
            bottom: BorderSide(color: AppColors.corporateYellow, width: 3),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.corporateYellow,
            foregroundColor: AppColors.ink,
            disabledBackgroundColor: const Color(0xffb8b5a6),
            disabledForegroundColor: const Color(0xff66645c),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.corporateYellow,
          linearTrackColor: Color(0xffc7c7bf),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xff272b2e),
            side: const BorderSide(color: Color(0xff55595b), width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xffdeded8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: const BorderSide(color: Color(0xff777975)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: const BorderSide(color: Color(0xff777975)),
          ),
        ),
      ),
      home: kIsWeb
          ? const AuthGate()
          : BleTerminalPage(requestBluetoothOnLaunch: requestBluetoothOnLaunch),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasData) {
        return SignedInAccessGate(key: ValueKey(snapshot.data!.uid));
      }
      return const LoginPage();
    },
  );
}

class SignedInAccessGate extends StatefulWidget {
  const SignedInAccessGate({super.key});

  @override
  State<SignedInAccessGate> createState() => _SignedInAccessGateState();
}

class _SignedInAccessGateState extends State<SignedInAccessGate> {
  bool? _cameraPermissionGranted;

  @override
  void initState() {
    super.initState();
    _checkCameraPermission();
  }

  Future<void> _checkCameraPermission() async {
    var granted = false;
    try {
      final status = await Permission.camera.status;
      granted = status.isGranted || status.isLimited;
    } catch (_) {
      granted = false;
    }
    if (mounted) setState(() => _cameraPermissionGranted = granted);
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraPermissionGranted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_cameraPermissionGranted!) {
      return DevicePermissionGate(
        onReady: () => setState(() => _cameraPermissionGranted = true),
      );
    }
    return const BleTerminalPage(requestBluetoothOnLaunch: false);
  }
}

class DevicePermissionGate extends StatefulWidget {
  const DevicePermissionGate({super.key, required this.onReady});

  final VoidCallback onReady;

  @override
  State<DevicePermissionGate> createState() => _DevicePermissionGateState();
}

class _DevicePermissionGateState extends State<DevicePermissionGate> {
  bool _cameraGranted = false;
  bool _requestingCamera = false;
  String? _error;

  Future<void> _requestCamera() async {
    setState(() {
      _requestingCamera = true;
      _error = null;
    });
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      setState(() {
        _cameraGranted = status.isGranted || status.isLimited;
        if (!_cameraGranted) {
          _error = 'QR 스캔을 사용하려면 카메라 권한을 허용해 주세요.';
        }
      });
      if (_cameraGranted) widget.onReady();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '카메라 권한을 요청하지 못했습니다. 브라우저 설정을 확인해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _requestingCamera = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('시작 전 권한 설정'),
      actions: [
        IconButton(
          onPressed: () => FirebaseAuth.instance.signOut(),
          tooltip: '로그아웃',
          icon: const Icon(Icons.logout_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: SeatCareCushionIcon(size: 60)),
                    const SizedBox(height: 16),
                    Text(
                      'Seat Care 사용 권한',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '방석 QR 인식에 필요한 카메라 권한을 먼저 허용해 주세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xff6f7482)),
                    ),
                    const SizedBox(height: 24),
                    _AccessStep(
                      number: 1,
                      icon: Icons.qr_code_scanner_rounded,
                      title: '카메라 권한',
                      description: _cameraGranted
                          ? '허용 완료'
                          : '방석의 QR 코드를 인식할 때 사용합니다.',
                      complete: _cameraGranted,
                      buttonLabel: _requestingCamera ? '요청 중…' : '카메라 허용',
                      onPressed: _requestingCamera || _cameraGranted
                          ? null
                          : _requestCamera,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      _ErrorNotice(
                        message: _error!,
                        onDismiss: () => setState(() => _error = null),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      '카메라를 허용하면 QR 연결 화면으로 바로 이동합니다. 자세 알림은 연결 후 앱 화면의 팝업으로 표시됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Color(0xff7a7f8d)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _AccessStep extends StatelessWidget {
  const _AccessStep({
    required this.number,
    required this.icon,
    required this.title,
    required this.description,
    required this.complete,
    required this.buttonLabel,
    required this.onPressed,
  });

  final int number;
  final IconData icon;
  final String title;
  final String description;
  final bool complete;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: complete ? const Color(0xffe9f8f2) : const Color(0xfff7f7f3),
      border: Border.all(
        color: complete ? const Color(0xff00a67e) : const Color(0xffd5d5ce),
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: complete
                  ? const Color(0xff00a67e)
                  : AppColors.corporateYellow,
              foregroundColor: complete ? Colors.white : AppColors.ink,
              child: complete
                  ? const Icon(Icons.check_rounded, size: 20)
                  : Text(
                      '$number',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
            ),
            const SizedBox(width: 12),
            Icon(icon, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(description, style: const TextStyle(color: Color(0xff646976))),
        const SizedBox(height: 12),
        FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
      ],
    ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _submitting = false;
  String? _message;

  String _authMessage(Object error) {
    if (error is! FirebaseAuthException) return '로그인 처리 중 오류가 발생했습니다.';
    return switch (error.code) {
      'popup-closed-by-user' || 'cancelled-popup-request' => '로그인이 취소되었습니다.',
      'popup-blocked' => '브라우저에서 로그인 팝업을 허용해 주세요.',
      'account-exists-with-different-credential' =>
        '같은 이메일이 다른 로그인 방식으로 이미 가입되어 있습니다.',
      'operation-not-allowed' => 'Firebase Console에서 해당 로그인 제공자를 활성화해 주세요.',
      'too-many-requests' => '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
      _ => '로그인 처리 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.',
    };
  }

  Future<void> _signIn(AuthProvider provider) async {
    setState(() {
      _submitting = true;
      _message = null;
    });
    try {
      await FirebaseAuth.instance.signInWithPopup(provider);
    } catch (error) {
      if (mounted) setState(() => _message = _authMessage(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    final provider = GoogleAuthProvider()
      ..addScope('email')
      ..setCustomParameters({'prompt': 'select_account'});
    await _signIn(provider);
  }

  Future<void> _signInWithApple() async {
    final provider = AppleAuthProvider()
      ..addScope('email')
      ..addScope('name')
      ..setCustomParameters({'locale': 'ko'});
    await _signIn(provider);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: SeatCareCushionIcon(size: 68)),
                    const SizedBox(height: 16),
                    Text(
                      'SEAT CARE',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '계정으로 로그인하세요',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xff6f7482)),
                    ),
                    const SizedBox(height: 26),
                    SizedBox(
                      height: 50,
                      child: OutlinedButton(
                        onPressed: _submitting ? null : _signInWithGoogle,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xff1f1f1f),
                          disabledBackgroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xff747775)),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            height: 20 / 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Image.asset(
                              'assets/images/google_g.png',
                              width: 20,
                              height: 20,
                              filterQuality: FilterQuality.high,
                            ),
                            const SizedBox(width: 10),
                            const Text('Google로 계속하기'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _submitting ? null : _signInWithApple,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xff555555),
                          disabledForegroundColor: Colors.white70,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.apple, size: 22),
                            SizedBox(width: 10),
                            Text('Apple로 계속하기'),
                          ],
                        ),
                      ),
                    ),
                    if (_submitting) ...[
                      const SizedBox(height: 18),
                      const Center(child: CircularProgressIndicator()),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _message!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xff9f1c1c),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    const Text(
                      '로그인하면 서비스 이용약관 및 개인정보 처리방침에 동의한 것으로 간주됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Color(0xff7a7f8d)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class SeatCareCushionIcon extends StatelessWidget {
  const SeatCareCushionIcon({super.key, this.size = 68});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Seat Care 방석',
    image: true,
    child: SizedBox(
      width: size,
      height: size * .72,
      child: const CustomPaint(painter: _SeatCareCushionPainter()),
    ),
  );
}

class _SeatCareCushionPainter extends CustomPainter {
  const _SeatCareCushionPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final silhouette = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    final shape = Path()
      ..moveTo(size.width * .19, size.height * .07)
      ..quadraticBezierTo(
        size.width * .50,
        -size.height * .01,
        size.width * .81,
        size.height * .07,
      )
      ..quadraticBezierTo(
        size.width * .95,
        size.height * .12,
        size.width * .91,
        size.height * .32,
      )
      ..lineTo(size.width * .83, size.height * .82)
      ..quadraticBezierTo(
        size.width * .80,
        size.height * .97,
        size.width * .64,
        size.height * .94,
      )
      ..quadraticBezierTo(
        size.width * .50,
        size.height * .89,
        size.width * .36,
        size.height * .94,
      )
      ..quadraticBezierTo(
        size.width * .20,
        size.height * .97,
        size.width * .17,
        size.height * .82,
      )
      ..lineTo(size.width * .09, size.height * .32)
      ..quadraticBezierTo(
        size.width * .05,
        size.height * .12,
        size.width * .19,
        size.height * .07,
      )
      ..close();
    canvas.drawPath(shape, silhouette);

    final seam = Paint()
      ..color = Colors.white.withValues(alpha: .58)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .025
      ..strokeCap = StrokeCap.round;
    final inset = Path()
      ..moveTo(size.width * .21, size.height * .27)
      ..quadraticBezierTo(
        size.width * .50,
        size.height * .19,
        size.width * .79,
        size.height * .27,
      )
      ..quadraticBezierTo(
        size.width * .76,
        size.height * .55,
        size.width * .69,
        size.height * .76,
      )
      ..quadraticBezierTo(
        size.width * .50,
        size.height * .69,
        size.width * .31,
        size.height * .76,
      )
      ..quadraticBezierTo(
        size.width * .24,
        size.height * .55,
        size.width * .21,
        size.height * .27,
      );
    canvas.drawPath(inset, seam);
  }

  @override
  bool shouldRepaint(covariant _SeatCareCushionPainter oldDelegate) => false;
}

class BleTerminalPage extends StatefulWidget {
  const BleTerminalPage({super.key, required this.requestBluetoothOnLaunch});

  final bool requestBluetoothOnLaunch;

  @override
  State<BleTerminalPage> createState() => _BleTerminalPageState();
}

class _BleTerminalPageState extends State<BleTerminalPage> {
  static final Guid _serviceId = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _rxId = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _txId = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');

  final _devices = <DeviceIdentifier, ScanResult>{};

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _calibrationTimeout;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  String? _connectionStage;
  CalibrationStatus _calibrationStatus = CalibrationStatus.checking;
  bool _isFirstSetup = false;
  List<int> _warningSensors = const [];
  String? _pendingDeviceCode;
  String? _error;
  PostureLean? _leanCandidate;
  DateTime? _leanStartedAt;
  DateTime? _lastPostureNotificationAt;
  String? _postureWarning;
  bool _posturePopupOpen = false;
  int _selectedTab = 0;
  List<double> _pressures = List<double>.filled(5, 0);

  @override
  void initState() {
    super.initState();
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      (results) {
        if (!mounted) return;
        setState(() {
          for (final result in results) {
            final name = result.advertisementData.advName.isNotEmpty
                ? result.advertisementData.advName
                : result.device.platformName;
            final advertisesService = result.advertisementData.serviceUuids
                .contains(_serviceId);
            if (DeviceCode.parse(name) != null ||
                name == 'ESP32-Pressure-6' ||
                name == 'ESP32-ADS1115' ||
                advertisesService) {
              _devices[result.device.remoteId] = result;
            }
          }
        });
      },
      onError: (Object error) => _reportBluetoothError(error, '기기 검색에 실패했습니다.'),
    );

    if (widget.requestBluetoothOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _requestBluetoothOnLaunch();
      });
    }
  }

  Future<void> _requestBluetoothOnLaunch() async {
    try {
      final granted = await _requestPermissions();
      if (!granted) {
        _showError('Bluetooth 권한이 필요합니다. 시스템 설정에서 권한을 허용해 주세요.');
      }
    } catch (error) {
      _reportBluetoothError(error, 'Bluetooth 권한을 확인할 수 없습니다.');
    }
  }

  Future<bool> _requestPermissions() async {
    // Web Bluetooth and camera permissions are requested by the browser from
    // the user gesture that starts scanning.
    if (kIsWeb) return true;
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      bool allowed(PermissionStatus? status) =>
          status?.isGranted == true || status?.isLimited == true;
      final modernBluetoothAllowed =
          allowed(statuses[Permission.bluetoothScan]) &&
          allowed(statuses[Permission.bluetoothConnect]);
      return modernBluetoothAllowed ||
          allowed(statuses[Permission.locationWhenInUse]);
    }
    return (await Permission.bluetooth.request()).isGranted;
  }

  Future<void> _scanDeviceCode() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DeviceCodeScannerPage()),
    );
    if (!mounted || code == null) return;
    await _applyDeviceCode(code);
  }

  Future<void> _applyDeviceCode(String code) async {
    if (kIsWeb) {
      setState(() {
        _pendingDeviceCode = code;
        _error = null;
      });
      return;
    }

    await _connectToDeviceCode(code);
  }

  Future<void> _enterDeviceCode() async {
    final controller = TextEditingController(text: _pendingDeviceCode ?? '');
    String? validationMessage;
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('기기 코드 직접 입력'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('QR 라벨에 표시된 6자리 코드를 입력하세요.'),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: '예: 01CC9C',
                  errorText: validationMessage,
                ),
                onSubmitted: (_) {
                  final parsed = DeviceCode.parse(controller.text);
                  if (parsed == null) {
                    setDialogState(
                      () => validationMessage = '영문 A–F와 숫자로 된 6자리를 입력해 주세요.',
                    );
                  } else {
                    Navigator.of(dialogContext).pop(parsed);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = DeviceCode.parse(controller.text);
                if (parsed == null) {
                  setDialogState(
                    () => validationMessage = '영문 A–F와 숫자로 된 6자리를 입력해 주세요.',
                  );
                } else {
                  Navigator.of(dialogContext).pop(parsed);
                }
              },
              child: const Text('코드 적용'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || code == null) return;
    await _applyDeviceCode(code);
  }

  Future<void> _connectToDeviceCode(String code) async {
    setState(() {
      _error = null;
      _isScanning = true;
      _connectionStage = '브라우저에서 ESP32를 선택해 주세요';
      _devices.clear();
    });
    try {
      if (!kIsWeb && !await _requestPermissions()) {
        throw StateError('Bluetooth 권한이 필요합니다.');
      }
      if (!kIsWeb) {
        final adapterState = await FlutterBluePlus.adapterState
            .where((state) => state != BluetoothAdapterState.unknown)
            .first;
        if (adapterState != BluetoothAdapterState.on) {
          throw StateError('Bluetooth를 켠 뒤 다시 시도해 주세요.');
        }
      }

      final matchingDevice = FlutterBluePlus.onScanResults
          .expand((results) => results)
          .firstWhere((result) {
            final advertisedCode = DeviceCode.fromScanResult(result);
            // Older Seat Care firmware used a fixed Bluetooth name. On web,
            // the service-filtered browser chooser is already a deliberate
            // user selection, so accept that legacy device when no code is
            // present. Still reject a different modern device code.
            return advertisedCode == code || (kIsWeb && advertisedCode == null);
          })
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () =>
                throw TimeoutException('기기 코드 $code에 해당하는 ESP32를 찾지 못했습니다.'),
          );
      await FlutterBluePlus.startScan(
        // A service filter supports both current ESP32-P-xxxxxx advertising
        // names and older Seat Care firmware names. optionalServices grants
        // access to the same GATT service after browser selection.
        withServices: [_serviceId],
        webOptionalServices: [_serviceId],
        timeout: const Duration(seconds: 12),
      );
      final result = await matchingDevice;
      await FlutterBluePlus.stopScan();
      if (mounted) {
        setState(() => _pendingDeviceCode = null);
        await _connect(result.device);
      }
    } catch (error) {
      await FlutterBluePlus.stopScan();
      _reportBluetoothError(error, '기기 코드와 일치하는 ESP32에 연결하지 못했습니다.');
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
          if (!_isConnecting) _connectionStage = null;
        });
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _error = null;
      _isConnecting = true;
      _connectionStage = 'ESP32에 연결을 요청하고 있어요';
    });
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      if (mounted) setState(() => _connectionStage = '통신 서비스를 확인하고 있어요');
      if (!kIsWeb && Platform.isAndroid) await device.requestMtu(64);
      _device = device;
      await _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (!mounted) return;
        setState(() {
          _isConnected = state == BluetoothConnectionState.connected;
          if (!_isConnected) {
            _calibrationStatus = CalibrationStatus.checking;
          }
        });
        if (state == BluetoothConnectionState.disconnected) {
          _rxCharacteristic = null;
        }
      });

      var services = await device.discoverServices();
      if (!services.any((item) => item.uuid == _serviceId)) {
        // Some browser/ESP32 combinations need a short interval after GATT
        // connection before custom services become visible.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        services = await device.discoverServices();
      }
      final service = services
          .where((item) => item.uuid == _serviceId)
          .firstOrNull;
      if (service == null) {
        throw StateError('ESP32 통신 서비스를 찾을 수 없습니다.');
      }
      _rxCharacteristic = service.characteristics
          .where((item) => item.uuid == _rxId)
          .firstOrNull;
      final tx = service.characteristics
          .where((item) => item.uuid == _txId)
          .firstOrNull;
      if (_rxCharacteristic == null || tx == null) {
        throw StateError('ESP32 송수신 채널을 찾을 수 없습니다.');
      }

      await _notificationSubscription?.cancel();
      if (mounted) setState(() => _connectionStage = '압력 데이터 채널을 준비하고 있어요');
      _notificationSubscription = tx.onValueReceived.listen((bytes) {
        if (!mounted) return;
        final text = utf8.decode(bytes, allowMalformed: true);
        final status = text.trim();
        if (status == 'S:SETUP_REQUIRED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _isFirstSetup = true;
            _warningSensors = const [];
            _calibrationStatus = CalibrationStatus.zeroRequired;
          });
          return;
        }
        if (status == 'S:ZERO_REQUIRED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _isFirstSetup = false;
            _calibrationStatus = CalibrationStatus.zeroRequired;
          });
          return;
        }
        if (status == 'S:CALIBRATING' || status == 'S:ZERO_CALIBRATING') {
          setState(
            () => _calibrationStatus = CalibrationStatus.zeroCalibrating,
          );
          return;
        }
        if (status == 'S:BALANCE_REQUIRED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _isFirstSetup = true;
            _calibrationStatus = CalibrationStatus.balanceRequired;
          });
          return;
        }
        if (status == 'S:BALANCE_CALIBRATING') {
          setState(
            () => _calibrationStatus = CalibrationStatus.balanceCalibrating,
          );
          return;
        }
        if (status.startsWith('S:ZERO_WARNING:')) {
          _calibrationTimeout?.cancel();
          setState(() {
            _warningSensors = _parseWarningSensors(status);
            _calibrationStatus = CalibrationStatus.zeroWarning;
          });
          return;
        }
        if (status.startsWith('S:BALANCE_WARNING:')) {
          _calibrationTimeout?.cancel();
          setState(() {
            _warningSensors = _parseWarningSensors(status);
            _calibrationStatus = CalibrationStatus.balanceWarning;
          });
          return;
        }
        if (status == 'S:CALIBRATION_FAILED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _warningSensors = const [];
            _calibrationStatus = CalibrationStatus.balanceWarning;
          });
          return;
        }
        if (status == 'S:ZERO_FAILED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _warningSensors = const [];
            _calibrationStatus = CalibrationStatus.zeroWarning;
          });
          return;
        }
        if (status == 'S:READY') {
          _calibrationTimeout?.cancel();
          setState(() => _calibrationStatus = CalibrationStatus.ready);
          return;
        }
        final frame = PressureFrame.tryParse(text);
        if (frame != null) _handlePressureFrame(frame);
      });
      await tx.setNotifyValue(true);
      if (mounted) {
        setState(() {
          _isConnected = true;
          _connectionStage = null;
          _calibrationStatus = CalibrationStatus.checking;
          _selectedTab = 0;
        });
      }
      await _requestCalibrationStatus();
    } catch (error) {
      await device.disconnect();
      _reportBluetoothError(error, 'ESP32 연결에 실패했습니다.');
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          if (!_isConnected) _connectionStage = null;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    await _device?.disconnect();
    if (!mounted) return;
    setState(() {
      _device = null;
      _rxCharacteristic = null;
      _isConnected = false;
      _selectedTab = 1;
      _calibrationStatus = CalibrationStatus.checking;
      _isFirstSetup = false;
      _warningSensors = const [];
      _leanCandidate = null;
      _leanStartedAt = null;
      _postureWarning = null;
      _pressures = List<double>.filled(5, 0);
    });
  }

  void _handlePressureFrame(PressureFrame frame) {
    final assessment = PostureAnalyzer.assess(frame.values);
    final now = DateTime.now();
    var warning = _postureWarning;

    if (_calibrationStatus != CalibrationStatus.ready ||
        assessment.lean == PostureLean.center ||
        assessment.lean == PostureLean.notSeated) {
      _leanCandidate = null;
      _leanStartedAt = null;
      if (assessment.lean == PostureLean.center) warning = null;
    } else if (_leanCandidate != assessment.lean) {
      _leanCandidate = assessment.lean;
      _leanStartedAt = now;
    } else {
      final startedAt = _leanStartedAt;
      final lastNotification = _lastPostureNotificationAt;
      final sustained =
          startedAt != null &&
          now.difference(startedAt) >= const Duration(seconds: 3);
      final cooledDown =
          lastNotification == null ||
          now.difference(lastNotification) >= const Duration(minutes: 1);
      if (sustained) {
        warning = assessment.message;
        if (cooledDown) {
          _lastPostureNotificationAt = now;
          unawaited(_showPosturePopup(assessment.message));
        }
      }
    }

    if (mounted) {
      setState(() {
        _pressures = frame.values;
        _postureWarning = warning;
      });
    }
  }

  Future<void> _showPosturePopup(String message) async {
    if (!mounted || _posturePopupOpen) return;
    _posturePopupOpen = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => PostureAlertDialog(message: message),
    );
    _posturePopupOpen = false;
  }

  Future<void> _requestCalibrationStatus() async {
    final rx = _rxCharacteristic;
    if (rx == null) return;
    try {
      await rx.write(
        utf8.encode('GET_CALIBRATION_STATUS'),
        withoutResponse: false,
      );
      _startCalibrationTimeout(
        const Duration(seconds: 5),
        '보정 정보를 확인할 수 없습니다. 방석 연결을 확인해 주세요.',
      );
    } catch (error) {
      debugPrint('보정 정보 확인 오류: $error');
      _showError('보정 정보를 확인하지 못했습니다. 방석 연결을 확인해 주세요.');
    }
  }

  void _startCalibrationTimeout(Duration duration, String message) {
    _calibrationTimeout?.cancel();
    _calibrationTimeout = Timer(duration, () {
      if (!mounted || _calibrationStatus == CalibrationStatus.ready) return;
      final waiting =
          _calibrationStatus == CalibrationStatus.checking ||
          _calibrationStatus == CalibrationStatus.zeroCalibrating ||
          _calibrationStatus == CalibrationStatus.balanceCalibrating;
      if (!waiting) return;
      setState(() {
        _calibrationStatus = _isFirstSetup
            ? CalibrationStatus.balanceRequired
            : CalibrationStatus.zeroRequired;
        _error = message;
      });
    });
  }

  Future<void> _startZeroCalibration() async {
    final rx = _rxCharacteristic;
    if (rx == null) return;
    setState(() {
      _error = null;
      _calibrationStatus = CalibrationStatus.zeroCalibrating;
    });
    try {
      await rx.write(utf8.encode('CALIBRATE_ZERO'), withoutResponse: false);
      _startCalibrationTimeout(
        const Duration(seconds: 9),
        '영점 보정 응답이 없습니다. 방석 연결을 확인해 주세요.',
      );
    } catch (error) {
      if (!mounted) return;
      debugPrint('영점 보정 시작 오류: $error');
      setState(() => _calibrationStatus = CalibrationStatus.zeroRequired);
      _showError('영점 보정을 시작하지 못했습니다. 방석 연결을 확인해 주세요.');
    }
  }

  Future<void> _startBalanceCalibration() async {
    final rx = _rxCharacteristic;
    if (rx == null) return;
    setState(() {
      _error = null;
      _calibrationStatus = CalibrationStatus.balanceCalibrating;
    });
    try {
      await rx.write(utf8.encode('CALIBRATE_BALANCE'), withoutResponse: false);
      _startCalibrationTimeout(
        const Duration(seconds: 9),
        '센서 균형 보정 응답이 없습니다. 방석 연결을 확인해 주세요.',
      );
    } catch (error) {
      if (!mounted) return;
      debugPrint('센서 균형 보정 시작 오류: $error');
      setState(() => _calibrationStatus = CalibrationStatus.balanceRequired);
      _showError('센서 균형 보정을 시작하지 못했습니다. 방석 연결을 확인해 주세요.');
    }
  }

  List<int> _parseWarningSensors(String status) {
    final separator = status.lastIndexOf(':');
    if (separator < 0 || separator == status.length - 1) return const [];
    return status
        .substring(separator + 1)
        .split(',')
        .map(int.tryParse)
        .whereType<int>()
        .toList(growable: false);
  }

  Future<void> _continueAfterCalibrationWarning() async {
    final rx = _rxCharacteristic;
    if (rx == null) return;
    final warningStatus = _calibrationStatus;
    final command = warningStatus == CalibrationStatus.zeroWarning
        ? 'CONTINUE_ZERO_CALIBRATION'
        : 'CONTINUE_BALANCE_CALIBRATION';
    setState(() {
      _warningSensors = const [];
      if (warningStatus == CalibrationStatus.zeroWarning) {
        _isFirstSetup = true;
        _calibrationStatus = CalibrationStatus.balanceRequired;
      } else {
        _calibrationStatus = CalibrationStatus.ready;
      }
    });
    try {
      await rx.write(utf8.encode(command), withoutResponse: false);
    } catch (error) {
      debugPrint('보정 계속 진행 오류: $error');
      _showError('보정을 계속 진행하지 못했습니다. 방석 연결을 확인해 주세요.');
    }
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  void _reportBluetoothError(Object error, String fallback) {
    debugPrint('Bluetooth 오류: $error');
    _showError(bluetoothErrorMessage(error, fallback: fallback));
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notificationSubscription?.cancel();
    _calibrationTimeout?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pageTitle = switch (_selectedTab) {
      1 => '기기 연결',
      2 => '설정',
      _ => 'ESP32 압력 모니터',
    };
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PRESSURE LINK',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.8,
                color: AppColors.corporateYellow,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              pageTitle,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(
                connected: _isConnected,
                connecting:
                    _isConnecting || (_isScanning && _connectionStage != null),
                deviceName: _device?.platformName,
                connectionStage: _connectionStage,
                onDisconnect: _isConnected ? _disconnect : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _ErrorNotice(
                  message: _error!,
                  onDismiss: () => setState(() => _error = null),
                ),
              ],
              const SizedBox(height: 20),
              if (_selectedTab == 2) ...[
                Expanded(child: _buildSettingsTab(context)),
              ] else if (_selectedTab == 1 && _isConnected) ...[
                Expanded(child: _buildConnectedDeviceTab(context)),
              ] else if (!_isConnected) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '주변 기기',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '방석의 QR 코드를 스캔해 연결을 시작하세요',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: const Color(0xff6f7482)),
                          ),
                        ],
                      ),
                    ),
                    _CountBadge(count: _devices.length),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PressureDemoPage(),
                      ),
                    ),
                    icon: const Icon(Icons.science_outlined, size: 20),
                    label: const Text(
                      '압력 화면 테스트',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: FilledButton.icon(
                          onPressed: _isScanning || _isConnecting
                              ? null
                              : _pendingDeviceCode == null
                              ? _scanDeviceCode
                              : () => _connectToDeviceCode(_pendingDeviceCode!),
                          icon: _isScanning
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _pendingDeviceCode == null
                                      ? Icons.qr_code_scanner_rounded
                                      : Icons.bluetooth_searching_rounded,
                                ),
                          label: Text(
                            _isScanning
                                ? '기기 확인 중…'
                                : _pendingDeviceCode == null
                                ? '기기 코드 스캔'
                                : 'Bluetooth 기기 선택 ($_pendingDeviceCode)',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: _isScanning || _isConnecting
                            ? null
                            : _enterDeviceCode,
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                        ),
                        child: const Icon(Icons.keyboard_alt_outlined),
                      ),
                    ),
                  ],
                ),
                if (_pendingDeviceCode != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _isScanning ? null : _scanDeviceCode,
                        icon: const Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 17,
                        ),
                        label: const Text('다시 스캔'),
                      ),
                      TextButton.icon(
                        onPressed: _isScanning
                            ? null
                            : () => setState(() {
                                _pendingDeviceCode = null;
                                _error = null;
                              }),
                        icon: const Icon(Icons.restart_alt_rounded, size: 17),
                        label: const Text('코드 초기화'),
                      ),
                    ],
                  ),
                  Text(
                    '코드 확인 완료 · 연결 버튼을 누르고 같은 ESP32를 선택하세요.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xff5f6470),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: _devices.isEmpty
                      ? _EmptyDevices(scanning: _isScanning)
                      : ListView(
                          padding: const EdgeInsets.only(top: 4),
                          children: _devices.values.map((result) {
                            final advertisedName =
                                result.advertisementData.advName;
                            final name = advertisedName.isNotEmpty
                                ? advertisedName
                                : result.device.platformName.isEmpty
                                ? 'ESP32 기기'
                                : result.device.platformName;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _DeviceCard(
                                name: name,
                                code: DeviceCode.fromScanResult(result),
                                rssi: result.rssi,
                                enabled: !_isConnecting,
                                onConnect: () => _connect(result.device),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ] else if (_calibrationStatus != CalibrationStatus.ready) ...[
                Expanded(
                  child: CalibrationPanel(
                    status: _calibrationStatus,
                    warningSensors: _warningSensors,
                    onStartZero: _startZeroCalibration,
                    onStartBalance: _startBalanceCalibration,
                    onContinueWarning: _continueAfterCalibrationWarning,
                  ),
                ),
              ] else ...[
                if (_postureWarning != null) ...[
                  _PostureWarning(message: _postureWarning!),
                  const SizedBox(height: 12),
                ],
                _PressureSummary(values: _pressures),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '방석 압력 분포',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'RBF · 20 Hz',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: const Color(0xff7a7f8d),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(child: PressureGrid(values: _pressures)),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() => _selectedTab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.bluetooth_outlined),
            selectedIcon: Icon(Icons.bluetooth_connected_rounded),
            label: '기기',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: '설정',
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedDeviceTab(BuildContext context) => ListView(
    children: [
      Text(
        '연결된 방석',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 10),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DeviceInfoRow(
                label: '기기 이름',
                value: _device?.platformName.isNotEmpty == true
                    ? _device!.platformName
                    : 'Seat Care ESP32',
              ),
              const Divider(height: 24),
              _DeviceInfoRow(
                label: '기기 코드',
                value: DeviceCode.parse(_device?.platformName) ?? '확인되지 않음',
              ),
              const Divider(height: 24),
              const _DeviceInfoRow(label: '데이터 수신', value: '20 Hz · 실시간'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        '다른 방석을 연결하려면 위 상태 카드의 연결 해제를 누른 뒤 QR을 다시 스캔하세요.',
        style: TextStyle(color: Color(0xff6f7482), height: 1.45),
      ),
    ],
  );

  Widget _buildSettingsTab(BuildContext context) => ListView(
    children: [
      _SettingsTile(
        icon: Icons.tune_rounded,
        title: '정자세 다시 보정',
        description: _isConnected
            ? '영점과 정자세 기준을 처음부터 다시 측정합니다.'
            : '방석을 연결한 뒤 사용할 수 있습니다.',
        enabled: _isConnected,
        onTap: () => setState(() {
          _isFirstSetup = false;
          _calibrationStatus = CalibrationStatus.zeroRequired;
          _selectedTab = 0;
        }),
      ),
      const SizedBox(height: 10),
      _SettingsTile(
        icon: Icons.science_outlined,
        title: '압력 화면 테스트',
        description: 'ESP32 없이 압력 분포와 보정 화면을 확인합니다.',
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const PressureDemoPage())),
      ),
      const SizedBox(height: 10),
      const _SettingsTile(
        icon: Icons.security_rounded,
        title: '권한 안내',
        description: '카메라는 QR 인식에만 사용하며 Bluetooth는 연결할 때 선택합니다.',
      ),
      if (kIsWeb) ...[
        const SizedBox(height: 10),
        _SettingsTile(
          icon: Icons.logout_rounded,
          title: '로그아웃',
          description: '현재 Seat Care 계정에서 로그아웃합니다.',
          onTap: () => FirebaseAuth.instance.signOut(),
        ),
      ],
    ],
  );
}

class _PostureWarning extends StatelessWidget {
  const _PostureWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xfffff3cd),
      border: Border.all(color: const Color(0xffd39e00)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.accessibility_new_rounded, color: Color(0xff8a6500)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: Color(0xff644c00),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );
}

class PostureAlertDialog extends StatelessWidget {
  const PostureAlertDialog({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(
      Icons.accessibility_new_rounded,
      size: 42,
      color: Color(0xffd39e00),
    ),
    title: const Text('자세를 바로잡아 주세요'),
    content: Text(message, textAlign: TextAlign.center),
    actionsAlignment: MainAxisAlignment.center,
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('확인'),
      ),
    ],
  );
}

class CalibrationPanel extends StatelessWidget {
  const CalibrationPanel({
    super.key,
    required this.status,
    this.warningSensors = const [],
    required this.onStartZero,
    required this.onStartBalance,
    required this.onContinueWarning,
  });

  final CalibrationStatus status;
  final List<int> warningSensors;
  final VoidCallback onStartZero;
  final VoidCallback onStartBalance;
  final VoidCallback onContinueWarning;

  @override
  Widget build(BuildContext context) {
    final checking = status == CalibrationStatus.checking;
    final balance =
        status == CalibrationStatus.balanceRequired ||
        status == CalibrationStatus.balanceCalibrating ||
        status == CalibrationStatus.balanceWarning;
    final warning =
        status == CalibrationStatus.zeroWarning ||
        status == CalibrationStatus.balanceWarning;
    final calibrating =
        status == CalibrationStatus.zeroCalibrating ||
        status == CalibrationStatus.balanceCalibrating;
    final title = checking
        ? '보정 정보를 확인하고 있어요'
        : balance
        ? calibrating
              ? '정자세 압력을 측정하고 있어요'
              : warning
              ? '센서 상태를 확인해 주세요'
              : '방석에 정자세로 앉아주세요'
        : calibrating
        ? '영점값을 측정하고 있어요'
        : warning
        ? '센서 상태를 확인해 주세요'
        : '먼저 방석을 비워주세요';
    final description = checking
        ? 'ESP32에 저장된 최초 보정 정보를 불러옵니다.'
        : balance
        ? calibrating
              ? '측정이 끝날 때까지 편안한 정자세를 유지하세요.'
              : warning
              ? '일부 센서 반응이 기준 범위를 벗어났습니다.'
              : '평소 바르게 앉았다고 생각하는 자세를 기준으로 저장합니다.'
        : calibrating
        ? '측정이 끝날 때까지 방석을 누르지 마세요.'
        : warning
        ? '일부 센서의 무부하 값이 기준 범위를 벗어났습니다.'
        : '사람이나 물건이 없는 상태를 0점으로 설정합니다.';
    final stepLabel = balance ? '캘리브레이션 · 2 / 2' : '캘리브레이션 · 1 / 2';
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.corporateYellow,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      stepLabel,
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xff747987)),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/images/cushion.png',
                      height: 230,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                  if (checking)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: CircularProgressIndicator(),
                    )
                  else if (calibrating)
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(seconds: 5),
                      builder: (context, progress, _) => Column(
                        children: [
                          LinearProgressIndicator(
                            value: progress,
                            minHeight: 7,
                          ),
                          const SizedBox(height: 9),
                          Text(
                            '${math.max(0, 5 - (progress * 5).floor())}초 남음',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Color(0xff6b5100),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (warning)
                    _CalibrationWarning(
                      sensors: warningSensors,
                      isZeroWarning: status == CalibrationStatus.zeroWarning,
                      onRetry: balance ? onStartBalance : onStartZero,
                      onContinue: onContinueWarning,
                    )
                  else if (balance)
                    const Column(
                      children: [
                        _CalibrationTip(
                          icon: Icons.airline_seat_recline_normal_rounded,
                          text: '방석 중앙에 앉아 허리와 골반을 바르게 세우세요.',
                        ),
                        SizedBox(height: 8),
                        _CalibrationTip(
                          icon: Icons.timer_outlined,
                          text: '평소의 정자세를 잡고 시작 후 5초 동안 유지하세요.',
                        ),
                      ],
                    )
                  else
                    const Column(
                      children: [
                        _CalibrationTip(
                          icon: Icons.event_seat_outlined,
                          text: '방석에서 일어나 압력을 완전히 제거하세요.',
                        ),
                        SizedBox(height: 8),
                        _CalibrationTip(
                          icon: Icons.timer_outlined,
                          text: '시작 후 5초 동안 방석을 그대로 두세요.',
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  if (!checking && !warning)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: calibrating
                            ? null
                            : balance
                            ? onStartBalance
                            : onStartZero,
                        icon: calibrating
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                balance
                                    ? Icons.airline_seat_recline_normal_rounded
                                    : Icons.tune_rounded,
                              ),
                        label: Text(
                          calibrating
                              ? '보정 진행 중'
                              : balance
                              ? '2단계 · 5초 정자세 보정 시작'
                              : '1단계 · 5초 무부하 보정 시작',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CalibrationWarning extends StatelessWidget {
  const _CalibrationWarning({
    required this.sensors,
    required this.isZeroWarning,
    required this.onRetry,
    required this.onContinue,
  });

  final List<int> sensors;
  final bool isZeroWarning;
  final VoidCallback onRetry;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final suspectedSensors = sensors
        .where(
          (sensor) =>
              sensor >= 1 && sensor <= PressureField.sensorLabels.length,
        )
        .map((sensor) {
          final index = sensor - 1;
          return '${PressureField.sensorLabels[index]} · S$sensor · ${PressureField.sensorLocationNames[index]}';
        })
        .toList(growable: false);
    final sensorLabel = suspectedSensors.isEmpty
        ? '일부 센서'
        : suspectedSensors.join(', ');
    final message = isZeroWarning
        ? '영점값이 정상 범위를 벗어났습니다. 무부하 센서가 있어도 그냥 계속하시겠습니까?'
        : '하중이 감지되지 않았습니다. 무부하 센서가 있어도 그냥 계속하시겠습니까?';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffff3cd),
        border: Border.all(color: const Color(0xffd39e00)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xffffdddd),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '고장 의심 센서: $sensorLabel',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xff9f1c1c),
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xff8a6500)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '$message 계속 진행하면 위 센서는 기본 보정값으로 사용됩니다.',
                  style: const TextStyle(
                    color: Color(0xff644c00),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('다시 측정'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onContinue,
                  child: const Text('그래도 계속 진행'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CalibrationTip extends StatelessWidget {
  const _CalibrationTip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe1e3e8)),
      borderRadius: BorderRadius.circular(2),
    ),
    child: Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xff59606e)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class PressureDemoPage extends StatefulWidget {
  const PressureDemoPage({super.key});

  @override
  State<PressureDemoPage> createState() => _PressureDemoPageState();
}

class _PressureDemoPageState extends State<PressureDemoPage> {
  static const _initialValues = <double>[120, 460, 820, 1280, 1710];

  Timer? _timer;
  Timer? _demoCalibrationTimer;
  double _phase = 0;
  bool _isPlaying = true;
  CalibrationStatus _demoCalibrationStatus = CalibrationStatus.zeroRequired;
  List<double> _values = List<double>.of(_initialValues);

  void _startDemoCalibration() {
    final balance =
        _demoCalibrationStatus == CalibrationStatus.balanceRequired ||
        _demoCalibrationStatus == CalibrationStatus.balanceWarning;
    setState(
      () => _demoCalibrationStatus = balance
          ? CalibrationStatus.balanceCalibrating
          : CalibrationStatus.zeroCalibrating,
    );
    _demoCalibrationTimer?.cancel();
    _demoCalibrationTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (balance) {
        setState(() => _demoCalibrationStatus = CalibrationStatus.ready);
        _startAnimation();
      } else {
        setState(
          () => _demoCalibrationStatus = CalibrationStatus.balanceRequired,
        );
      }
    });
  }

  void _startAnimation() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      _phase += .14;
      setState(() {
        _values = List<double>.generate(5, (index) {
          final wave = (math.sin(_phase + index * .82) + 1) / 2;
          final pulse = math.max(0.0, math.sin(_phase * .58 - index * .35));
          return (60 + wave * (680 + index * 105) + pulse * 480).clamp(
            0,
            PressureGrid.displayMaximum,
          );
        });
      });
    });
  }

  void _toggleAnimation() {
    setState(() => _isPlaying = !_isPlaying);
    if (_isPlaying) {
      _startAnimation();
    } else {
      _timer?.cancel();
    }
  }

  void _reset() {
    setState(() {
      _phase = 0;
      _values = List<double>.of(_initialValues);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _demoCalibrationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_demoCalibrationStatus != CalibrationStatus.ready) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            '압력 화면 테스트',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: CalibrationPanel(
              status: _demoCalibrationStatus,
              onStartZero: _startDemoCalibration,
              onStartBalance: _startDemoCalibration,
              onContinueWarning: () {},
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '압력 화면 테스트',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xffd7d7d1),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: const Color(0xffdde1e9)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.science_outlined, color: Color(0xff383c3e)),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'ESP32 없이 표시 화면을 확인하는 시뮬레이션입니다.',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _PressureSummary(values: _values),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '48 × 72 압력 그리드',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _isPlaying
                          ? const Color(0xff00a67e)
                          : const Color(0xff8a8f9d),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isPlaying ? '재생 중' : '일시정지',
                    style: const TextStyle(
                      color: Color(0xff6e7482),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(child: PressureGrid(values: _values)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _reset,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('초기값'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _toggleAnimation,
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(_isPlaying ? '일시정지' : '재생'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DeviceCode {
  const DeviceCode._();

  static String? parse(String? rawValue) {
    if (rawValue == null) return null;
    final value = rawValue.trim().toUpperCase();
    final match = RegExp(
      r'^(?:ESP32[:\-]P?[:\-]?)?([0-9A-F]{6})$',
    ).firstMatch(value);
    return match?.group(1);
  }

  static String? fromScanResult(ScanResult result) {
    final advertisedName = result.advertisementData.advName;
    return parse(
      advertisedName.isEmpty ? result.device.platformName : advertisedName,
    );
  }
}

class DeviceCodeScannerPage extends StatefulWidget {
  const DeviceCodeScannerPage({super.key});

  @override
  State<DeviceCodeScannerPage> createState() => _DeviceCodeScannerPageState();
}

class _DeviceCodeScannerPageState extends State<DeviceCodeScannerPage> {
  bool _handled = false;
  String? _error;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final code = DeviceCode.parse(barcode.rawValue);
      if (code != null) {
        _handled = true;
        Navigator.of(context).pop(code);
        return;
      }
    }
    if (mounted) {
      setState(() => _error = 'ESP32 기기 코드가 아닌 바코드입니다.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('기기 코드 스캔'),
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: _onDetect,
          errorBuilder: (context, error) => ColoredBox(
            color: Colors.black,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.no_photography_outlined,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      scannerErrorMessage(error),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        IgnorePointer(child: CustomPaint(painter: _ScannerOverlayPainter())),
        Positioned(
          left: 24,
          right: 24,
          bottom: 42,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .76),
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'ESP32 기기의 QR 또는 바코드를 사각형 안에 맞추세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xffff8c8c)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scanRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * .43),
      width: size.width - 64,
      height: 190,
    );
    final overlay = Path()
      ..addRect(Offset.zero & size)
      ..addRect(scanRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlay, Paint()..color = Colors.black54);
    canvas.drawRect(
      scanRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum PostureLean { notSeated, center, left, right, front, back }

class PostureAssessment {
  const PostureAssessment(this.lean, this.score);

  final PostureLean lean;
  final double score;

  String get message => switch (lean) {
    PostureLean.left => '왼쪽으로 치우쳐 있어요. 몸을 방석 중앙으로 옮겨 주세요.',
    PostureLean.right => '오른쪽으로 치우쳐 있어요. 몸을 방석 중앙으로 옮겨 주세요.',
    PostureLean.front => '앞쪽으로 치우쳐 있어요. 엉덩이를 뒤로 옮겨 주세요.',
    PostureLean.back => '뒤쪽으로 치우쳐 있어요. 상체를 정자세로 세워 주세요.',
    PostureLean.center => '정자세를 잘 유지하고 있어요.',
    PostureLean.notSeated => '착석 압력이 감지되지 않았습니다.',
  };
}

abstract final class PostureAnalyzer {
  static PostureAssessment assess(
    List<double> values, {
    double minimumTotalPressure = 125,
    double leanThreshold = .20,
  }) {
    if (values.length != 5) {
      return const PostureAssessment(PostureLean.notSeated, 0);
    }
    final total = values.fold<double>(
      0,
      (sum, value) => sum + math.max(0, value),
    );
    if (total < minimumTotalPressure) {
      return const PostureAssessment(PostureLean.notSeated, 0);
    }

    // Sensor order: L1, R1, L2, R2, C1. Balance calibration normalizes
    // their reference response, so comparing side averages is relative to the
    // user's saved upright posture rather than raw sensor sensitivity.
    final left = (values[0] + values[2]) / 2;
    final right = (values[1] + values[3]) / 2;
    final front = (values[0] + values[1]) / 2;
    final back = (values[2] + values[3] + values[4]) / 3;
    final lateral = (right - left) / math.max(1, right + left);
    final longitudinal = (front - back) / math.max(1, front + back);

    if (lateral.abs() < leanThreshold && longitudinal.abs() < leanThreshold) {
      return const PostureAssessment(PostureLean.center, 0);
    }
    if (lateral.abs() >= longitudinal.abs()) {
      return PostureAssessment(
        lateral > 0 ? PostureLean.right : PostureLean.left,
        lateral.abs(),
      );
    }
    return PostureAssessment(
      longitudinal > 0 ? PostureLean.front : PostureLean.back,
      longitudinal.abs(),
    );
  }
}

class PressureFrame {
  const PressureFrame(this.values);

  final List<double> values;

  static PressureFrame? tryParse(String packet) {
    final text = packet.trim();
    if (!text.startsWith('P:')) return null;
    final parts = text.substring(2).split(',');
    if (parts.length != 5) return null;
    final values = <double>[];
    for (final part in parts) {
      final value = double.tryParse(part);
      if (value == null || !value.isFinite || value < 0) return null;
      values.add(value);
    }
    return PressureFrame(List.unmodifiable(values));
  }
}

class PressureField {
  const PressureField._();

  static const sensorLabels = <String>['L1', 'R1', 'L2', 'R2', 'C1'];
  static const sensorLocationNames = <String>[
    '왼쪽 앞',
    '오른쪽 앞',
    '왼쪽 뒤',
    '오른쪽 뒤',
    '중앙 후방',
  ];

  // 배치 도면의 40 x 40 좌표를 0~1 범위로 정규화했습니다.
  // 화면 위쪽은 앞무릎 방향, 아래쪽은 뒤 등받이 방향입니다.
  static const sensorPositions = <Offset>[
    Offset(.300, .300), // L1 (12, 12)
    Offset(.700, .300), // R1 (28, 12)
    Offset(.325, .675), // L2 (13, 27)
    Offset(.675, .675), // R2 (27, 27)
    Offset(.500, .850), // C1 (20, 34)
  ];
  static const double _sigma = .34;
  static const double _regularization = .002;
  static final Map<String, List<List<double>>> _projectionCache = {};

  static List<List<double>> interpolate(
    List<double> sensorValues, {
    int rows = 72,
    int columns = 48,
    double maximum = PressureGrid.displayMaximum,
  }) {
    assert(rows > 1 && columns > 1);
    final values = List<double>.generate(
      sensorPositions.length,
      (index) => index < sensorValues.length ? sensorValues[index] : 0,
    );
    final projection = _projection(rows, columns);

    return List<List<double>>.generate(rows, (row) {
      return List<double>.generate(columns, (column) {
        final coefficients = projection[row * columns + column];
        var estimate = 0.0;
        for (var index = 0; index < sensorPositions.length; index++) {
          estimate += coefficients[index] * values[index];
        }
        return estimate.clamp(0.0, maximum);
      });
    });
  }

  static List<List<double>> _projection(int rows, int columns) {
    final key = 'regular:$rows:$columns';
    final cached = _projectionCache[key];
    if (cached != null) return cached;

    final size = sensorPositions.length;
    final kernelMatrix = List<List<double>>.generate(
      size,
      (row) => List<double>.generate(size, (column) {
        final value = _kernel(
          sensorPositions[row].dx - sensorPositions[column].dx,
          sensorPositions[row].dy - sensorPositions[column].dy,
        );
        return row == column ? value + _regularization : value;
      }),
    );
    final inverse = List<List<double>>.generate(
      size,
      (_) => List<double>.filled(size, 0),
    );
    for (var column = 0; column < size; column++) {
      final basis = List<double>.filled(size, 0)..[column] = 1;
      final solution = _solve(kernelMatrix, basis);
      for (var row = 0; row < size; row++) {
        inverse[row][column] = solution[row];
      }
    }

    final result = List<List<double>>.generate(rows * columns, (flatIndex) {
      final row = flatIndex ~/ columns;
      final column = flatIndex % columns;
      final y = (row + .5) / rows;
      final x = (column + .5) / columns;
      final sampleKernel = List<double>.generate(
        size,
        (index) => _kernel(
          x - sensorPositions[index].dx,
          y - sensorPositions[index].dy,
        ),
      );
      return List<double>.generate(size, (output) {
        var coefficient = 0.0;
        for (var input = 0; input < size; input++) {
          coefficient += sampleKernel[input] * inverse[input][output];
        }
        return coefficient;
      });
    });
    _projectionCache[key] = result;
    return result;
  }

  static double _kernel(double dx, double dy) {
    final distanceSquared = dx * dx + dy * dy;
    return math.exp(-distanceSquared / (2 * _sigma * _sigma));
  }

  static List<double> _solve(List<List<double>> matrix, List<double> vector) {
    final size = vector.length;
    final augmented = List<List<double>>.generate(
      size,
      (row) => [...matrix[row], vector[row]],
    );

    for (var pivot = 0; pivot < size; pivot++) {
      var bestRow = pivot;
      for (var row = pivot + 1; row < size; row++) {
        if (augmented[row][pivot].abs() > augmented[bestRow][pivot].abs()) {
          bestRow = row;
        }
      }
      final temporary = augmented[pivot];
      augmented[pivot] = augmented[bestRow];
      augmented[bestRow] = temporary;

      final divisor = augmented[pivot][pivot];
      if (divisor.abs() < 1e-12) continue;
      for (var column = pivot; column <= size; column++) {
        augmented[pivot][column] /= divisor;
      }
      for (var row = 0; row < size; row++) {
        if (row == pivot) continue;
        final factor = augmented[row][pivot];
        for (var column = pivot; column <= size; column++) {
          augmented[row][column] -= factor * augmented[pivot][column];
        }
      }
    }
    return List<double>.generate(size, (row) => augmented[row][size]);
  }
}

class PressureGrid extends StatelessWidget {
  const PressureGrid({super.key, required this.values});

  final List<double> values;
  static const double displayMaximum = 3200;

  @override
  Widget build(BuildContext context) {
    final sensorValues = List<double>.generate(
      5,
      (index) => index < values.length ? values[index] : 0,
    );
    final field = PressureField.interpolate(sensorValues);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          constraints.maxWidth,
          constraints.maxHeight * .80,
        );
        final height = width / .80;
        const top = 24.0;
        final bodyHeight = height - top * 2;
        final markerSize = math.min(50.0, width * .14);

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CushionGridPainter(
                      field: field,
                      maximum: displayMaximum,
                    ),
                  ),
                ),
                const Positioned(
                  top: 5,
                  left: 0,
                  right: 0,
                  child: Text(
                    '앞 · 무릎 방향',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xff7c8290),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Positioned(
                  bottom: 4,
                  left: 0,
                  right: 0,
                  child: Text(
                    '뒤 · 등받이 방향',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xff7c8290),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (var index = 0; index < sensorValues.length; index++)
                  Positioned(
                    left:
                        PressureField.sensorPositions[index].dx * width -
                        markerSize / 2,
                    top:
                        top +
                        PressureField.sensorPositions[index].dy * bodyHeight -
                        markerSize / 2,
                    width: markerSize,
                    height: markerSize,
                    child: _PressureSensorMarker(
                      key: ValueKey('pressure-sensor-${index + 1}'),
                      sensorNumber: index + 1,
                      sensorLabel: PressureField.sensorLabels[index],
                      value: sensorValues[index],
                      maximum: displayMaximum,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Color _pressureHeatColor(double intensity) {
  if (intensity < .04) return const Color(0xff3b424d);
  if (intensity < .5) {
    return Color.lerp(
      const Color(0xff9cddcf),
      const Color(0xffffd166),
      intensity * 2,
    )!;
  }
  return Color.lerp(
    const Color(0xffffd166),
    const Color(0xffff5c5c),
    (intensity - .5) * 2,
  )!;
}

class _CushionGridPainter extends CustomPainter {
  const _CushionGridPainter({required this.field, required this.maximum});

  final List<List<double>> field;
  final double maximum;

  @override
  void paint(Canvas canvas, Size size) {
    final top = 24.0;
    final bottom = size.height - 24;
    final rows = field.length;
    final columns = field.first.length;
    final rowHeight = (bottom - top) / rows;
    final cellWidth = size.width / columns;
    final path = Path()
      ..moveTo(size.width * .18, top)
      ..lineTo(size.width * .82, top)
      ..quadraticBezierTo(size.width - 4, top, size.width - 2, top + 54)
      ..lineTo(size.width - 10, bottom - 42)
      ..quadraticBezierTo(size.width - 14, bottom, size.width * .76, bottom)
      ..lineTo(size.width * .24, bottom)
      ..quadraticBezierTo(14, bottom, 10, bottom - 42)
      ..lineTo(2, top + 54)
      ..quadraticBezierTo(4, top, size.width * .18, top)
      ..close();

    canvas.drawShadow(path, Colors.black.withValues(alpha: .18), 10, false);
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(path, Paint()..color = const Color(0xff242932));
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final intensity = (field[row][column] / maximum).clamp(0.0, 1.0);
        canvas.drawRect(
          Rect.fromLTWH(
            column * cellWidth,
            top + row * rowHeight,
            cellWidth + .35,
            rowHeight + .35,
          ),
          Paint()..color = _pressureHeatColor(intensity),
        );
      }
    }
    final guidePaint = Paint()
      ..color = Colors.black.withValues(alpha: .07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .6;
    for (var column = 4; column < columns; column += 4) {
      canvas.drawLine(
        Offset(column * cellWidth, top),
        Offset(column * cellWidth, bottom),
        guidePaint,
      );
    }
    for (var row = 4; row < rows; row += 4) {
      canvas.drawLine(
        Offset(0, top + row * rowHeight),
        Offset(size.width, top + row * rowHeight),
        guidePaint,
      );
    }
    canvas.restore();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff15191f)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _CushionGridPainter oldDelegate) {
    if (maximum != oldDelegate.maximum ||
        field.length != oldDelegate.field.length ||
        field.first.length != oldDelegate.field.first.length) {
      return true;
    }
    for (var row = 0; row < field.length; row++) {
      for (var column = 0; column < field[row].length; column++) {
        if (field[row][column] != oldDelegate.field[row][column]) return true;
      }
    }
    return false;
  }
}

class _PressureSensorMarker extends StatelessWidget {
  const _PressureSensorMarker({
    super.key,
    required this.sensorNumber,
    required this.sensorLabel,
    required this.value,
    required this.maximum,
  });

  final int sensorNumber;
  final String sensorLabel;
  final double value;
  final double maximum;

  @override
  Widget build(BuildContext context) {
    final intensity = (value / maximum).clamp(0.0, 1.0);
    final markerColor = intensity > .72
        ? AppColors.corporateYellow
        : const Color(0xffe9e5d8);

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: markerColor,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xff171a1c), width: 1.5),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$sensorLabel · S$sensorNumber',
              style: const TextStyle(
                color: Color(0xff4e5050),
                fontSize: 9,
                fontWeight: FontWeight.w900,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              value.toStringAsFixed(0),
              style: const TextStyle(
                color: Color(0xff111314),
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: -.5,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.connected,
    required this.connecting,
    this.deviceName,
    this.connectionStage,
    this.onDisconnect,
  });
  final bool connected;
  final bool connecting;
  final String? deviceName;
  final String? connectionStage;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final color = connected
        ? const Color(0xff00a67e)
        : connecting
        ? const Color(0xffff9f1c)
        : const Color(0xff8a8f9d);
    final label = connected
        ? '${deviceName ?? 'ESP32'} 연결됨'
        : connecting
        ? '연결하는 중…'
        : '연결되지 않음';
    final description = connected
        ? '압력 데이터를 실시간으로 수신하고 있어요'
        : connecting
        ? connectionStage ?? '잠시만 기다려 주세요'
        : 'Bluetooth로 ESP32를 연결해 주세요';
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: const BorderSide(color: Color(0xff999b97)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Icon(
                connected
                    ? Icons.bluetooth_connected_rounded
                    : Icons.bluetooth_disabled_rounded,
                color: color,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xff777c89),
                    ),
                  ),
                ],
              ),
            ),
            if (onDisconnect != null)
              OutlinedButton.icon(
                onPressed: onDisconnect,
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('연결 해제'),
              )
            else
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
    decoration: BoxDecoration(
      color: const Color(0xffffeded),
      borderRadius: BorderRadius.circular(2),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline_rounded, color: Color(0xffc93f46)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: Color(0xff7c282d),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: onDismiss,
          tooltip: '닫기',
          icon: const Icon(Icons.close_rounded, size: 20),
        ),
      ],
    ),
  );
}

class _DeviceInfoRow extends StatelessWidget {
  const _DeviceInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 88,
        child: Text(label, style: const TextStyle(color: Color(0xff747987))),
      ),
      Expanded(
        child: Text(
          value,
          textAlign: TextAlign.right,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.description,
    this.enabled = true,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(description),
      trailing: onTap == null || !enabled
          ? null
          : const Icon(Icons.chevron_right_rounded),
    ),
  );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: AppColors.corporateYellow,
      borderRadius: BorderRadius.circular(2),
    ),
    child: Text(
      '$count개 발견',
      style: const TextStyle(
        color: AppColors.ink,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.name,
    required this.code,
    required this.rssi,
    required this.enabled,
    required this.onConnect,
  });

  final String name;
  final String? code;
  final int rssi;
  final bool enabled;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final signalLabel = rssi >= -60
        ? '신호 좋음'
        : rssi >= -80
        ? '신호 보통'
        : '신호 약함';
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: const BorderSide(color: Color(0xff999b97)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xffd7d7d1),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.memory_rounded, color: Color(0xff373c4a)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$signalLabel · $rssi dBm',
                    style: const TextStyle(
                      color: Color(0xff747987),
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    code == null ? '기기 코드 없음' : '기기 코드  $code',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff6e7482),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: enabled ? onConnect : null,
              child: const Text('연결'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PressureSummary extends StatelessWidget {
  const _PressureSummary({required this.values});

  final List<double> values;

  @override
  Widget build(BuildContext context) {
    final peak = values.isEmpty
        ? 0.0
        : values.reduce((current, next) => current > next ? current : next);
    final average = values.isEmpty
        ? 0.0
        : values.reduce((a, b) => a + b) / values.length;
    final active = values.where((value) => value >= 100).length;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xff202427),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xff050606), width: 2),
      ),
      child: Row(
        children: [
          _SummaryValue(label: '평균', value: average.toStringAsFixed(0)),
          const _SummaryDivider(),
          _SummaryValue(label: '최고', value: peak.toStringAsFixed(0)),
          const _SummaryDivider(),
          _SummaryValue(label: '활성 센서', value: '$active / 5'),
        ],
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: .68),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        FittedBox(
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.corporateYellow,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    ),
  );
}

class _SummaryDivider extends StatelessWidget {
  const _SummaryDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 34,
    color: Colors.white.withValues(alpha: .18),
  );
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: const Color(0xffd3d3cd),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Icon(
              scanning ? Icons.radar_rounded : Icons.sensors_rounded,
              size: 42,
              color: const Color(0xff303436),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            scanning ? 'ESP32를 찾고 있어요' : '아직 검색된 기기가 없어요',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            scanning ? '가까운 기기를 검색하는 중입니다' : '위의 검색 버튼을 눌러 시작하세요',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xff7a7f8d)),
          ),
        ],
      ),
    ),
  );
}
