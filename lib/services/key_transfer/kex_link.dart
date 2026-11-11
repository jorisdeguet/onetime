import 'dart:typed_data';

import '../../models/firestore/fs_kex.dart';
import 'kex_wire.dart';

/// Source end of a local link (Bluetooth): readers nearby connect to it,
/// acknowledge blocks and receive the session state, with no server round trip.
abstract class KexHostLink {
  /// Starts accepting readers of [session]; throws when the link is unavailable
  /// (Bluetooth off, permission refused, peripheral role not supported).
  Future<void> start(FsKex session, void Function(KexReaderMessage message) onMessage);

  /// Sends the current state to every connected reader (latest one wins).
  void publish(FsKex state);

  /// Readers subscribed to the key stream (Bluetooth mode).
  int get dataReceivers;

  /// Sends one (encrypted) packet to every subscribed reader; completes once
  /// it is handed to the radio, which paces the stream.
  Future<void> sendData(Uint8List message);

  Future<void> stop();
}

/// Reader end of a local link.
abstract class KexClientLink {
  /// Finds the source showing [sessionId] and connects; throws when it is not
  /// found within [timeout] or the link is unavailable.
  Future<void> connect(String sessionId, String participantId, {Duration timeout});

  /// Session states sent by the source.
  Stream<FsKex> get states;

  /// Packets of the key stream (Bluetooth mode), still encrypted.
  Stream<Uint8List> get data;

  bool get isConnected;

  Future<void> send(KexReaderMessage message);

  Future<void> close();
}

/// Key stream of the Bluetooth mode, as the controllers see it (implemented
/// by [HybridKexSyncChannel] next to the acknowledgements).
abstract class KexDataLink {
  /// Source: completes once readers can connect; fails when Bluetooth is
  /// unavailable (the exchange then falls back to QR codes).
  Future<void> get hostReady;

  /// Source: readers subscribed to the key stream.
  int get dataReceivers;

  /// Source: sends one encrypted packet to every subscribed reader.
  Future<void> sendData(Uint8List message);

  /// Source: packets the slowest connected reader got up to (sequence number).
  int get packetsReceivedBySlowest;

  /// Reader: connects to the source of [sessionId]; fails when not found.
  Future<void> connectReader(String sessionId);

  /// Reader: encrypted packets from the source.
  Stream<Uint8List> get data;

  /// Reader: tells the source how far the stream arrived (flow control).
  void reportReceived(int packets);
}
