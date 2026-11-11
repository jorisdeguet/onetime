import 'dart:async';
import 'dart:convert';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/firestore/fs_kex.dart';
import '../app_logger.dart';
import 'kex_link.dart';
import 'kex_wire.dart';

/// GATT layout shared by both ends of the Bluetooth link.
///
/// The source is the peripheral: it advertises the service with a short tag
/// of the session id, so a reader that scanned a code connects to the right
/// phone. Readers write to [control] and subscribe to [state], and in
/// Bluetooth mode to [data] (encrypted key packets).
class BleKexGatt {
  static final service = UUID.fromString('5f1e0001-0e7a-4c1a-9a1d-7d0f3a6b2c01');
  static final control = UUID.fromString('5f1e0002-0e7a-4c1a-9a1d-7d0f3a6b2c01');
  static final state = UUID.fromString('5f1e0003-0e7a-4c1a-9a1d-7d0f3a6b2c01');
  static final data = UUID.fromString('5f1e0004-0e7a-4c1a-9a1d-7d0f3a6b2c01');

  /// Company id reserved for tests; the advertisement must stay within 31
  /// bytes: flags (3) + service UUID (18) + this data (4 + tag).
  static const manufacturerId = 0xFFFF;

  static Uint8List sessionTag(String sessionId) =>
      Uint8List.fromList(sha256.convert(ascii.encode(sessionId)).bytes.sublist(0, 6));

  /// Waits for a known adapter state and asks for the permissions if needed.
  static Future<void> ensureReady(BluetoothLowEnergyManager manager) async {
    var state = manager.state;
    if (state == BluetoothLowEnergyState.unknown) {
      state = await manager.stateChanged
          .map((e) => e.state)
          .firstWhere((s) => s != BluetoothLowEnergyState.unknown)
          .timeout(const Duration(seconds: 3), onTimeout: () => manager.state);
    }
    if (state == BluetoothLowEnergyState.unauthorized) {
      if (!await manager.authorize()) throw StateError('Bluetooth permission refused');
      // The plugin does not refresh its state after a grant: the next call
      // fails on its own if the adapter is off
      return;
    }
    if (state != BluetoothLowEnergyState.poweredOn) throw StateError('Bluetooth ${state.name}');
  }
}

/// Source end of the Bluetooth link: a GATT server.
class BleKexHost implements KexHostLink {
  final _log = AppLogger();
  PeripheralManager? _manager;
  final GATTCharacteristic _control = GATTCharacteristic.mutable(
    uuid: BleKexGatt.control,
    properties: [GATTCharacteristicProperty.write],
    permissions: [GATTCharacteristicPermission.write],
    descriptors: [],
  );
  final GATTCharacteristic _state = GATTCharacteristic.mutable(
    uuid: BleKexGatt.state,
    properties: [GATTCharacteristicProperty.notify],
    permissions: [GATTCharacteristicPermission.read],
    descriptors: [],
  );
  final GATTCharacteristic _data = GATTCharacteristic.mutable(
    uuid: BleKexGatt.data,
    properties: [GATTCharacteristicProperty.notify],
    permissions: [GATTCharacteristicPermission.read],
    descriptors: [],
  );
  final Map<UUID, Central> _subscribers = {};
  final Map<UUID, Central> _dataSubscribers = {};
  final Map<UUID, int> _notifyLength = {};
  final Map<UUID, KexFrameReader> _incoming = {};
  Future<void> _notifying = Future.value();
  final List<StreamSubscription<Object>> _subscriptions = [];
  FsKex? _latest;
  bool _dirty = false;
  Future<void>? _pump;

  @override
  Future<void> start(FsKex session, void Function(KexReaderMessage message) onMessage) async {
    final pm = _manager = PeripheralManager();
    await BleKexGatt.ensureReady(pm);
    _subscriptions
      ..add(pm.characteristicWriteRequested.listen((e) async {
        if (e.characteristic.uuid != BleKexGatt.control) {
          await pm.respondWriteRequestWithError(e.request, error: GATTError.writeNotPermitted);
          return;
        }
        await pm.respondWriteRequest(e.request);
        final bytes = _incoming.putIfAbsent(e.central.uuid, KexFrameReader.new).add(e.request.value);
        if (bytes == null) return;
        try {
          onMessage(KexWire.decodeReaderMessage(bytes));
        } catch (err) {
          _log.w('KeyExchange', 'Unreadable message over Bluetooth: $err');
        }
      }))
      ..add(pm.characteristicNotifyStateChanged.listen((e) {
        if (e.characteristic.uuid == BleKexGatt.data) {
          e.state ? _dataSubscribers[e.central.uuid] = e.central : _dataSubscribers.remove(e.central.uuid);
          return;
        }
        if (e.characteristic.uuid != BleKexGatt.state) return;
        if (e.state) {
          _subscribers[e.central.uuid] = e.central;
          _schedule();
        } else {
          _subscribers.remove(e.central.uuid);
        }
      }))
      ..add(pm.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) {
          _subscribers.remove(e.central.uuid);
          _dataSubscribers.remove(e.central.uuid);
          _notifyLength.remove(e.central.uuid);
          _incoming.remove(e.central.uuid);
        }
      }));
    await pm.removeAllServices();
    await pm.addService(GATTService(
      uuid: BleKexGatt.service,
      isPrimary: true,
      includedServices: [],
      characteristics: [_control, _state, _data],
    ));
    await pm.startAdvertising(Advertisement(
      serviceUUIDs: [BleKexGatt.service],
      manufacturerSpecificData: [
        ManufacturerSpecificData(id: BleKexGatt.manufacturerId, data: BleKexGatt.sessionTag(session.id)),
      ],
    ));
  }

  @override
  void publish(FsKex state) {
    _latest = state;
    _schedule();
  }

  @override
  int get dataReceivers => _dataSubscribers.length;

  @override
  Future<void> sendData(Uint8List message) async {
    for (final central in _dataSubscribers.values.toList()) {
      try {
        await _notify(central, _data, message);
      } catch (e) {
        _log.w('KeyExchange', 'Bluetooth packet not sent: $e');
      }
    }
  }

  /// Sends [message] as notifications of [characteristic]. The plugin
  /// handles one notification at a time, so every send goes through here.
  Future<void> _notify(Central central, GATTCharacteristic characteristic, Uint8List message) {
    final pm = _manager;
    final next = _notifying.catchError((_) {}).then((_) async {
      if (pm == null) throw StateError('Bluetooth host stopped');
      // Read each time: the reader raises the MTU after subscribing
      final max = await pm.getMaximumNotifyLength(central);
      if (_notifyLength[central.uuid] != max) {
        _notifyLength[central.uuid] = max;
        _log.i('KeyExchange', 'Bluetooth notifications of up to $max bytes');
      }
      for (final frame in KexWire.frame(message, max)) {
        await pm.notifyCharacteristic(central, characteristic, value: frame);
      }
    });
    _notifying = next;
    return next;
  }

  void _schedule() {
    _dirty = true;
    _pump ??= _sendLatest();
  }

  /// Sends the latest state to every subscriber, one notification at a time;
  /// states published meanwhile collapse into the next round.
  Future<void> _sendLatest() async {
    try {
      while (_dirty && _latest != null && _subscribers.isNotEmpty) {
        _dirty = false;
        final bytes = KexWire.encodeState(_latest!);
        for (final central in _subscribers.values.toList()) {
          try {
            await _notify(central, _state, bytes);
          } catch (e) {
            _log.w('KeyExchange', 'Bluetooth notification failed: $e');
          }
        }
      }
    } finally {
      _pump = null;
    }
  }

  @override
  Future<void> stop() async {
    final pm = _manager;
    if (pm == null) return;
    _manager = null;
    // Lets the last state (completion) reach the readers first
    await _pump?.timeout(const Duration(seconds: 2), onTimeout: () {});
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    try {
      await pm.stopAdvertising();
      for (final central in _subscribers.values) {
        await pm.disconnect(central);
      }
      await pm.removeAllServices();
    } catch (e) {
      _log.w('KeyExchange', 'Bluetooth cleanup failed: $e');
    }
    _subscribers.clear();
    _dataSubscribers.clear();
    _notifyLength.clear();
  }
}

/// Reader end of the Bluetooth link: a GATT client.
class BleKexClient implements KexClientLink {
  final _log = AppLogger();
  CentralManager? _manager;
  Peripheral? _peripheral;
  GATTCharacteristic? _control;
  int _maxWrite = 20;
  bool _connected = false;
  final KexFrameReader _incoming = KexFrameReader();
  final KexFrameReader _incomingData = KexFrameReader();
  final StreamController<FsKex> _states = StreamController.broadcast();
  final StreamController<Uint8List> _data = StreamController.broadcast();
  final List<StreamSubscription<Object>> _subscriptions = [];
  Future<void> _sending = Future.value();

  @override
  Stream<FsKex> get states => _states.stream;

  @override
  Stream<Uint8List> get data => _data.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(String sessionId, String participantId, {Duration timeout = const Duration(seconds: 6)}) async {
    final cm = _manager = CentralManager();
    await BleKexGatt.ensureReady(cm);
    final tag = BleKexGatt.sessionTag(sessionId);
    final found = Completer<Peripheral>();
    final discovery = cm.discovered.listen((e) {
      final match = e.advertisement.manufacturerSpecificData
          .any((d) => d.id == BleKexGatt.manufacturerId && listEquals(d.data, tag));
      if (match && !found.isCompleted) found.complete(e.peripheral);
    });
    final Peripheral peripheral;
    try {
      await cm.startDiscovery(serviceUUIDs: [BleKexGatt.service]);
      peripheral = await found.future.timeout(timeout);
    } finally {
      await discovery.cancel();
      await cm.stopDiscovery();
    }
    _peripheral = peripheral;
    _subscriptions
      ..add(cm.connectionStateChanged.listen((e) {
        if (e.peripheral.uuid == peripheral.uuid && e.state == ConnectionState.disconnected) {
          _connected = false;
          _log.w('KeyExchange', 'Bluetooth link to the source lost');
        }
      }))
      ..add(cm.characteristicNotified.listen((e) {
        if (e.peripheral.uuid != peripheral.uuid) return;
        if (e.characteristic.uuid == BleKexGatt.data) {
          final packet = _incomingData.add(e.value);
          if (packet != null) _data.add(packet);
          return;
        }
        if (e.characteristic.uuid != BleKexGatt.state) return;
        final bytes = _incoming.add(e.value);
        if (bytes == null) return;
        try {
          _states.add(KexWire.decodeState(bytes));
        } catch (err) {
          _log.w('KeyExchange', 'Unreadable state over Bluetooth: $err');
        }
      }));
    await cm.connect(peripheral);
    try {
      await cm.requestMTU(peripheral, mtu: 247);
    } catch (e) {
      _log.d('KeyExchange', 'MTU request refused: $e');
    }
    final services = await cm.discoverGATT(peripheral);
    final service = services.firstWhere((s) => s.uuid == BleKexGatt.service);
    _control = service.characteristics.firstWhere((c) => c.uuid == BleKexGatt.control);
    final state = service.characteristics.firstWhere((c) => c.uuid == BleKexGatt.state);
    await cm.setCharacteristicNotifyState(peripheral, state, state: true);
    final data = service.characteristics.where((c) => c.uuid == BleKexGatt.data).firstOrNull;
    if (data != null) await cm.setCharacteristicNotifyState(peripheral, data, state: true);
    _maxWrite = await cm.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);
    _connected = true;
    await send(KexHello(participantId, sessionId));
  }

  /// Messages go out one after the other, each frame acknowledged by the source.
  @override
  Future<void> send(KexReaderMessage message) {
    final next = _sending.catchError((_) {}).then((_) async {
      final cm = _manager, peripheral = _peripheral, control = _control;
      if (!_connected || cm == null || peripheral == null || control == null) {
        throw StateError('Not connected');
      }
      for (final frame in KexWire.frame(KexWire.encodeReaderMessage(message), _maxWrite)) {
        await cm.writeCharacteristic(peripheral, control, value: frame, type: GATTCharacteristicWriteType.withResponse);
      }
    });
    _sending = next;
    return next;
  }

  @override
  Future<void> close() async {
    _connected = false;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    final cm = _manager, peripheral = _peripheral;
    _manager = null;
    _peripheral = null;
    if (cm != null && peripheral != null) {
      try {
        await cm.disconnect(peripheral);
      } catch (e) {
        _log.d('KeyExchange', 'Bluetooth disconnect failed: $e');
      }
    }
    await _states.close();
    await _data.close();
  }
}
