import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const Esp32App());

class Esp32App extends StatelessWidget {
  const Esp32App({super.key, this.requestBluetoothOnLaunch = true});

  final bool requestBluetoothOnLaunch;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32 Terminal',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff006c67),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
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
  final _messages = <TerminalMessage>[];
  final _devices = <DeviceIdentifier, ScanResult>{};

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final result in results) {
          final name = result.device.platformName;
          final advertisesService = result.advertisementData.serviceUuids
              .contains(_serviceId);
          if (name == 'ESP32-ADS1115' || advertisesService) {
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
      _device = device;
      await _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (!mounted) return;
        setState(
          () => _isConnected = state == BluetoothConnectionState.connected,
        );
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
        setState(() => _messages.insert(0, TerminalMessage.received(text)));
      });
      await tx.setNotifyValue(true);
      if (mounted) setState(() => _isConnected = true);
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
    });
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    final rx = _rxCharacteristic;
    if (text.isEmpty || rx == null) return;
    try {
      await rx.write(utf8.encode(text), withoutResponse: false);
      if (!mounted) return;
      setState(() => _messages.insert(0, TerminalMessage.sent(text)));
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
    _messageController.dispose();
    _device?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 BLE Terminal'),
        actions: [
          if (_isConnected)
            TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect'),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                MaterialBanner(
                  content: Text(_error!),
                  leading: const Icon(Icons.error_outline),
                  actions: [
                    TextButton(
                      onPressed: () => setState(() => _error = null),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              if (!_isConnected) ...[
                FilledButton.icon(
                  onPressed: _isScanning || _isConnecting ? null : _startScan,
                  icon: _isScanning
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(_isScanning ? 'Scanning…' : 'Scan for ESP32'),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _devices.isEmpty
                      ? const _EmptyDevices()
                      : ListView(
                          children: _devices.values.map((result) {
                            final name = result.device.platformName.isEmpty
                                ? 'ESP32 device'
                                : result.device.platformName;
                            return Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  child: Icon(Icons.memory),
                                ),
                                title: Text(name),
                                subtitle: Text(
                                  '${result.device.remoteId}  •  ${result.rssi} dBm',
                                ),
                                trailing: FilledButton.tonal(
                                  onPressed: _isConnecting
                                      ? null
                                      : () => _connect(result.device),
                                  child: const Text('Connect'),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ] else ...[
                Text(
                  'Messages',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _messages.isEmpty
                      ? const Center(child: Text('Waiting for ESP32 data…'))
                      : ListView.builder(
                          reverse: true,
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final message = _messages[index];
                            return _MessageBubble(message: message);
                          },
                        ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Message to ESP32',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _send,
                      tooltip: 'Send',
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class TerminalMessage {
  const TerminalMessage(this.text, this.isSent, this.timestamp);
  factory TerminalMessage.sent(String text) =>
      TerminalMessage(text, true, DateTime.now());
  factory TerminalMessage.received(String text) =>
      TerminalMessage(text, false, DateTime.now());

  final String text;
  final bool isSent;
  final DateTime timestamp;
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
        ? Colors.green
        : connecting
        ? Colors.orange
        : Colors.grey;
    final label = connected
        ? 'Connected to ${deviceName ?? 'ESP32'}'
        : connecting
        ? 'Connecting…'
        : 'Not connected';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();
  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.radar, size: 56),
        SizedBox(height: 12),
        Text('Power the ESP32, then tap Scan.'),
      ],
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final TerminalMessage message;

  @override
  Widget build(BuildContext context) {
    final time =
        '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}:${message.timestamp.second.toString().padLeft(2, '0')}';
    return Align(
      alignment: message.isSent ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: message.isSent
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message.text),
              const SizedBox(height: 3),
              Text(
                '${message.isSent ? 'Sent' : 'Received'} • $time',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
