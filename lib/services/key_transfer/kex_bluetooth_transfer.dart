import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base45.dart';

/// The only QR code of a Bluetooth key exchange: which session to join and
/// the one-time secret that encrypts the key bytes sent over Bluetooth.
///
/// Anyone listening to the radio sees only AES-256-GCM ciphertext; reading
/// the key needs this code as well, seen from a few centimetres. Unlike the
/// QR mode, the key is then only as safe as AES (computational security).
class KexInvite {
  static const version = 3;
  static const secretLength = 32;

  final String sessionId;
  final int totalBytes;
  final Uint8List secret;

  KexInvite({required this.sessionId, required this.totalBytes, required this.secret});

  factory KexInvite.generate({required String sessionId, required int totalBytes}) {
    final random = Random.secure();
    return KexInvite(
      sessionId: sessionId,
      totalBytes: totalBytes,
      secret: Uint8List.fromList(List.generate(secretLength, (_) => random.nextInt(256))),
    );
  }

  /// Base45 (QR alphanumeric mode): version (1), id length (1), id,
  /// total bytes (4), secret (32).
  String encode() {
    final id = ascii.encode(sessionId);
    final b = ByteData(6 + id.length + secretLength)
      ..setUint8(0, version)
      ..setUint8(1, id.length);
    final bytes = b.buffer.asUint8List()
      ..setRange(2, 2 + id.length, id)
      ..setRange(6 + id.length, 6 + id.length + secretLength, secret);
    b.setUint32(2 + id.length, totalBytes);
    return Base45.encode(bytes);
  }

  /// The invite in [payload], or null when it is another kind of code.
  static KexInvite? tryDecode(String payload) {
    try {
      final bytes = Base45.decode(payload);
      if (bytes.length < 2 || bytes[0] != version) return null;
      final idLength = bytes[1];
      if (bytes.length != 6 + idLength + secretLength) return null;
      final d = ByteData.sublistView(bytes);
      return KexInvite(
        sessionId: ascii.decode(bytes.sublist(2, 2 + idLength)),
        totalBytes: d.getUint32(2 + idLength),
        secret: Uint8List.fromList(bytes.sublist(6 + idLength)),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Encrypts the packets of one Bluetooth exchange with the invite's secret.
/// Nonces are a counter: only the source encrypts with this key.
class KexPacketCipher {
  static final _aes = AesGcm.with256bits();
  final SecretKey _key;
  final List<int> _aad;
  int _counter = 0;

  KexPacketCipher(KexInvite invite)
      : _key = SecretKey(invite.secret),
        _aad = ascii.encode(invite.sessionId);

  Future<Uint8List> encrypt(Uint8List packet) async {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, _counter++);
    final box = await _aes.encrypt(packet, secretKey: _key, nonce: nonce, aad: _aad);
    return box.concatenation();
  }

  /// Position of an encrypted packet in the stream (its nonce counter).
  static int sequenceOf(Uint8List message) => ByteData.sublistView(message, 4, 12).getUint64(0);

  /// Throws [SecretBoxAuthenticationError] for anything not sent by the source.
  Future<Uint8List> decrypt(Uint8List message) async {
    final box = SecretBox.fromConcatenation(message, nonceLength: 12, macLength: 16);
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: _key, aad: _aad));
  }
}
