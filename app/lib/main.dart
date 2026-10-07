import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const Esp32App());

enum CalibrationStatus {
  checking,
  zeroRequired,
  zeroCalibrating,
  balanceRequired,
  balanceCalibrating,
  ready,
}

abstract final class AppColors {
  static const corporateYellow = Color(0xffffc928);
  static const ink = Color(0xff202427);
  static const canvas = Color(0xffe7e7e1);
  static const surface = Color(0xfff1f1ec);
}

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
      home: BleTerminalPage(requestBluetoothOnLaunch: requestBluetoothOnLaunch),
    );
  }
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

  final _messageController = TextEditingController();
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
  CalibrationStatus _calibrationStatus = CalibrationStatus.checking;
  bool _isFirstSetup = false;
  String? _error;
  List<double> _pressures = List<double>.filled(5, 0);

  @override
  void initState() {
    super.initState();
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final result in results) {
          final name = result.advertisementData.advName.isNotEmpty
              ? result.advertisementData.advName
              : result.device.platformName;
          final advertisesService = result.advertisementData.serviceUuids
              .contains(_serviceId);
          if (name == 'ESP32-Pressure-6' ||
              name == 'ESP32-ADS1115' ||
              advertisesService) {
            _devices[result.device.remoteId] = result;
          }
        }
      });
    }, onError: (Object error) => _showError('Scan failed: $error'));

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
        _showError(
          'Bluetooth permission is required. Enable it in system settings.',
        );
      }
    } catch (error) {
      _showError('Could not request Bluetooth permission: $error');
    }
  }

  Future<bool> _requestPermissions() async {
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

  Future<void> _startScan() async {
    setState(() => _error = null);
    if (!await _requestPermissions()) {
      _showError('Bluetooth permission is required to find the ESP32.');
      return;
    }

    try {
      final adapterState = await FlutterBluePlus.adapterState
          .where((state) => state != BluetoothAdapterState.unknown)
          .first;
      if (adapterState != BluetoothAdapterState.on) {
        _showError('Turn on Bluetooth, then scan again.');
        return;
      }
      setState(() {
        _devices.clear();
        _isScanning = true;
      });
      await FlutterBluePlus.startScan(
        withServices: [_serviceId],
        timeout: const Duration(seconds: 8),
      );
      await FlutterBluePlus.isScanning.where((value) => !value).first;
    } catch (error) {
      _showError('Could not scan: $error');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _scanDeviceCode() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DeviceCodeScannerPage()),
    );
    if (!mounted || code == null) return;

    setState(() {
      _error = null;
      _isScanning = true;
      _devices.clear();
    });
    try {
      if (!await _requestPermissions()) {
        throw StateError('Bluetooth 권한이 필요합니다.');
      }
      final adapterState = await FlutterBluePlus.adapterState
          .where((state) => state != BluetoothAdapterState.unknown)
          .first;
      if (adapterState != BluetoothAdapterState.on) {
        throw StateError('Bluetooth를 켠 뒤 다시 시도해 주세요.');
      }

      final matchingDevice = FlutterBluePlus.onScanResults
          .expand((results) => results)
          .firstWhere((result) => DeviceCode.fromScanResult(result) == code)
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () =>
                throw TimeoutException('기기 코드 $code에 해당하는 ESP32를 찾지 못했습니다.'),
          );
      await FlutterBluePlus.startScan(
        withServices: [_serviceId],
        timeout: const Duration(seconds: 12),
      );
      final result = await matchingDevice;
      await FlutterBluePlus.stopScan();
      if (mounted) await _connect(result.device);
    } catch (error) {
      await FlutterBluePlus.stopScan();
      _showError('바코드 연결 실패: $error');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _error = null;
      _isConnecting = true;
    });
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      if (Platform.isAndroid) await device.requestMtu(64);
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

      final services = await device.discoverServices();
      final service = services
          .where((item) => item.uuid == _serviceId)
          .firstOrNull;
      if (service == null) throw StateError('ESP32 BLE service was not found.');
      _rxCharacteristic = service.characteristics
          .where((item) => item.uuid == _rxId)
          .firstOrNull;
      final tx = service.characteristics
          .where((item) => item.uuid == _txId)
          .firstOrNull;
      if (_rxCharacteristic == null || tx == null) {
        throw StateError('ESP32 RX/TX characteristics were not found.');
      }

      await _notificationSubscription?.cancel();
      _notificationSubscription = tx.onValueReceived.listen((bytes) {
        if (!mounted) return;
        final text = utf8.decode(bytes, allowMalformed: true);
        final status = text.trim();
        if (status == 'S:SETUP_REQUIRED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _isFirstSetup = true;
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
        if (status == 'S:CALIBRATION_FAILED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _calibrationStatus = CalibrationStatus.balanceRequired;
            _error = '기준 하중이 모든 센서에 전달되지 않았습니다. 판과 하중을 다시 확인해 주세요.';
          });
          return;
        }
        if (status == 'S:ZERO_FAILED') {
          _calibrationTimeout?.cancel();
          setState(() {
            _calibrationStatus = CalibrationStatus.zeroRequired;
            _error = '무부하 전압이 낮은 센서가 있습니다. 센서 배선과 방석 위의 물체를 확인해 주세요.';
          });
          return;
        }
        if (status == 'S:READY') {
          _calibrationTimeout?.cancel();
          setState(() => _calibrationStatus = CalibrationStatus.ready);
          return;
        }
        final frame = PressureFrame.tryParse(text);
        if (frame != null) setState(() => _pressures = frame.values);
      });
      await tx.setNotifyValue(true);
      if (mounted) {
        setState(() {
          _isConnected = true;
          _calibrationStatus = CalibrationStatus.checking;
        });
      }
      await _requestCalibrationStatus();
    } catch (error) {
      await device.disconnect();
      _showError('Connection failed: $error');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    await _device?.disconnect();
    if (!mounted) return;
    setState(() {
      _device = null;
      _rxCharacteristic = null;
      _isConnected = false;
      _calibrationStatus = CalibrationStatus.checking;
      _isFirstSetup = false;
      _pressures = List<double>.filled(5, 0);
    });
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
      _showError('보정 정보 확인 실패: $error');
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
      setState(() => _calibrationStatus = CalibrationStatus.zeroRequired);
      _showError('영점 보정 시작 실패: $error');
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
      setState(() => _calibrationStatus = CalibrationStatus.balanceRequired);
      _showError('센서 균형 보정 시작 실패: $error');
    }
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    final rx = _rxCharacteristic;
    if (text.isEmpty || rx == null) return;
    try {
      await rx.write(utf8.encode(text), withoutResponse: false);
      if (!mounted) return;
      _messageController.clear();
    } catch (error) {
      _showError('Send failed: $error');
    }
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notificationSubscription?.cancel();
    _calibrationTimeout?.cancel();
    _messageController.dispose();
    _device?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PRESSURE LINK',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.8,
                color: AppColors.corporateYellow,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'ESP32 압력 모니터',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          if (_isConnected && _calibrationStatus == CalibrationStatus.ready)
            IconButton(
              onPressed: () => setState(() {
                _isFirstSetup = false;
                _calibrationStatus = CalibrationStatus.zeroRequired;
              }),
              tooltip: '영점 다시 맞추기',
              icon: const Icon(Icons.tune_rounded),
            ),
          if (_isConnected)
            IconButton.filledTonal(
              onPressed: _disconnect,
              tooltip: '연결 해제',
              icon: const Icon(Icons.link_off_rounded),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(
                connected: _isConnected,
                connecting: _isConnecting,
                deviceName: _device?.platformName,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _ErrorNotice(
                  message: _error!,
                  onDismiss: () => setState(() => _error = null),
                ),
              ],
              const SizedBox(height: 20),
              if (!_isConnected) ...[
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
                            'ESP32의 전원이 켜져 있는지 확인하세요',
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
                              : _scanDeviceCode,
                          icon: _isScanning
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.qr_code_scanner_rounded),
                          label: Text(
                            _isScanning ? '기기 확인 중…' : '기기 코드 스캔',
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
                            : _startScan,
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                        ),
                        child: const Icon(Icons.bluetooth_searching_rounded),
                      ),
                    ),
                  ],
                ),
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
                                ? 'ESP32 device'
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
                    firstSetup: _isFirstSetup,
                    onStartZero: _startZeroCalibration,
                    onStartBalance: _startBalanceCalibration,
                  ),
                ),
              ] else ...[
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
                const SizedBox(height: 10),
                _MessageComposer(controller: _messageController, onSend: _send),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class CalibrationPanel extends StatelessWidget {
  const CalibrationPanel({
    super.key,
    required this.status,
    required this.firstSetup,
    required this.onStartZero,
    required this.onStartBalance,
  });

  final CalibrationStatus status;
  final bool firstSetup;
  final VoidCallback onStartZero;
  final VoidCallback onStartBalance;

  @override
  Widget build(BuildContext context) {
    final checking = status == CalibrationStatus.checking;
    final balance =
        status == CalibrationStatus.balanceRequired ||
        status == CalibrationStatus.balanceCalibrating;
    final calibrating =
        status == CalibrationStatus.zeroCalibrating ||
        status == CalibrationStatus.balanceCalibrating;
    final title = checking
        ? '보정 정보를 확인하고 있어요'
        : balance
        ? calibrating
              ? '센서별 반응을 측정하고 있어요'
              : '센서 균형을 맞춰주세요'
        : calibrating
        ? '영점값을 측정하고 있어요'
        : '먼저 방석을 비워주세요';
    final description = checking
        ? 'ESP32에 저장된 최초 보정 정보를 불러옵니다.'
        : balance
        ? calibrating
              ? '측정이 끝날 때까지 판과 기준 하중을 움직이지 마세요.'
              : '이 단계는 처음 사용할 때 한 번만 진행합니다.'
        : calibrating
        ? '측정이 끝날 때까지 방석을 누르지 마세요.'
        : '사람이나 물건이 없는 상태를 0점으로 설정합니다.';
    final stepLabel = firstSetup
        ? balance
              ? '최초 설정 · 2 / 2'
              : '최초 설정 · 1 / 2'
        : '영점 설정 · 1 / 1';
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
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
              SizedBox(
                height: 290,
                child: PressureGrid(values: List<double>.filled(5, 0)),
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
                      LinearProgressIndicator(value: progress, minHeight: 7),
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
              else if (balance)
                const Column(
                  children: [
                    _CalibrationTip(
                      icon: Icons.crop_landscape_rounded,
                      text: '방석 전체를 덮는 단단하고 평평한 판을 올리세요.',
                    ),
                    SizedBox(height: 8),
                    _CalibrationTip(
                      icon: Icons.fitness_center_rounded,
                      text: '판 중앙에 기준 하중을 올리고 5초 동안 고정하세요.',
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
              if (!checking)
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            balance
                                ? Icons.balance_rounded
                                : Icons.tune_rounded,
                          ),
                    label: Text(
                      calibrating
                          ? '보정 진행 중'
                          : balance
                          ? '5초 센서 균형 보정 시작'
                          : '5초 영점 보정 시작',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
            ],
          ),
        ),
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
    setState(() => _demoCalibrationStatus = CalibrationStatus.zeroCalibrating);
    _demoCalibrationTimer?.cancel();
    _demoCalibrationTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _demoCalibrationStatus = CalibrationStatus.ready);
      _startAnimation();
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
              firstSetup: false,
              onStartZero: _startDemoCalibration,
              onStartBalance: _startDemoCalibration,
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
        MobileScanner(onDetect: _onDetect),
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

  static const sensorPositions = <Offset>[
    Offset(.28, .18),
    Offset(.72, .18),
    Offset(.50, .50),
    Offset(.22, .82),
    Offset(.78, .82),
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
                    '등받이 쪽',
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
                    '방석 앞쪽',
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
    required this.value,
    required this.maximum,
  });

  final int sensorNumber;
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
              'S$sensorNumber',
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
  });
  final bool connected;
  final bool connecting;
  final String? deviceName;

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
        ? '잠시만 기다려 주세요'
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

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({required this.controller, required this.onSend});

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(2),
    ),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: const InputDecoration(
              hintText: 'ESP32에 명령 보내기',
              prefixIcon: Icon(Icons.terminal_rounded),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: onSend,
          tooltip: '전송',
          icon: const Icon(Icons.arrow_upward_rounded),
        ),
      ],
    ),
  );
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) => Center(
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
  );
}
