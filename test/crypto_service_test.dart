import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/models/firestore/fs_message.dart';
import 'package:onetime/models/local/shared_key.dart';
import 'package:onetime/services/crypto_service.dart';

SharedKey _key(int bytes) {
  final random = Random(42);
  return SharedKey(
    id: 'c1',
    keyData: Uint8List.fromList(List.generate(bytes, (_) => random.nextInt(256))),
    peerIds: ['alice', 'bob'],
    nextAvailableByte: 0,
  );
}

/// The message as the receiver reads it from Firestore: range and bytes only.
EncryptedMessage _received(EncryptedMessage sent, {Uint8List? ciphertext, int? startByte, int? lengthBytes}) =>
    EncryptedMessage(
      keySegment: (
        startByte: startByte ?? sent.keySegment.startByte,
        lengthBytes: lengthBytes ?? sent.keySegment.lengthBytes,
      ),
      ciphertext: ciphertext ?? Uint8List.fromList(sent.ciphertext),
    );

void main() {
  final crypto = CryptoService();

  test('round trip: the range holds the MAC key, the ciphertext the tag', () {
    final key = _key(1000);
    final sent = crypto.encrypt(plaintext: 'bonjour', sharedKey: key, senderId: 'alice').message;
    expect(sent.keySegment.lengthBytes, sent.ciphertext.length - CryptoService.tagBytes + CryptoService.macKeyBytes);
    expect(crypto.decrypt(encryptedMessage: _received(sent), sharedKey: key), 'bonjour');
  });

  test('binary content round trip', () {
    final key = _key(5000);
    final data = Uint8List.fromList(List.generate(3000, (i) => i % 251));
    final sent = crypto.encryptBinary(
      data: data,
      sharedKey: key,
      senderId: 'bob',
      contentType: MessageContentType.image,
      fileName: 'a.jpg',
      mimeType: 'image/jpeg',
    ).message;
    expect(crypto.decryptBinary(encryptedMessage: _received(sent), sharedKey: key), data);
  });

  test('any flipped bit is detected, in the body or in the tag', () {
    final key = _key(1000);
    final sent = crypto.encrypt(plaintext: 'rendez-vous à 18h', sharedKey: key, senderId: 'alice').message;
    for (int i = 0; i < sent.ciphertext.length; i++) {
      final tampered = Uint8List.fromList(sent.ciphertext)..[i] ^= 0x01;
      expect(
        () => crypto.decrypt(encryptedMessage: _received(sent, ciphertext: tampered), sharedKey: key),
        throwsA(isA<MessageAuthenticationException>()),
        reason: 'byte $i',
      );
    }
  });

  test('a message moved to another key range is rejected', () {
    final key = _key(1000);
    final sent = crypto.encrypt(plaintext: 'salut', sharedKey: key, senderId: 'alice').message;
    expect(
      () => crypto.decrypt(encryptedMessage: _received(sent, startByte: sent.keySegment.startByte + 100), sharedKey: key),
      throwsA(isA<MessageAuthenticationException>()),
    );
  });

  test('truncated, extended or untagged ciphertexts are rejected', () {
    final key = _key(1000);
    final sent = crypto.encrypt(plaintext: 'salut', sharedKey: key, senderId: 'alice').message;
    final c = sent.ciphertext;
    for (final wrong in [
      Uint8List.sublistView(c, 0, c.length - 1),
      Uint8List.fromList([...c, 0]),
      Uint8List(sent.keySegment.lengthBytes), // old format: ciphertext as long as the range
    ]) {
      expect(
        () => crypto.decrypt(encryptedMessage: _received(sent, ciphertext: wrong), sharedKey: key),
        throwsA(isA<MessageAuthenticationException>()),
      );
    }
  });

  test('a forgery made without the key is rejected', () {
    final key = _key(1000);
    final random = Random(7);
    final forged = EncryptedMessage(
      keySegment: (startByte: 200, lengthBytes: 64),
      ciphertext: Uint8List.fromList(List.generate(64 - CryptoService.macKeyBytes + CryptoService.tagBytes, (_) => random.nextInt(256))),
    );
    expect(() => crypto.decrypt(encryptedMessage: forged, sharedKey: key), throwsA(isA<MessageAuthenticationException>()));
  });
}
