import 'dart:convert';
import 'dart:typed_data';

import 'package:onetime/convo/encrypted_message.dart';

import '../convo/compression_service.dart';
import '../key_exchange/key_interval.dart';
import '../key_exchange/shared_key.dart';

class CryptoService {
  
  /// Service de compression
  final CompressionService _compressionService = CompressionService();

  CryptoService();

  /// Chiffre un message avec One-Time Pad.
  /// 
  /// [plaintext] - Le message en clair
  /// [sharedKey] - La clé partagée à utiliser
  /// [deleteAfterRead] - Mode ultra-secure, suppression après lecture
  /// [compress] - Compresser le message avant chiffrement (défaut: true)
  /// 
  /// Retourne le message chiffré et l'intervalle utilisé pour mise à jour
  ({EncryptedMessage message, KeyInterval usedSegment}) encrypt({
    required String plaintext,
    required SharedKey sharedKey,
  }) {
    // Préparer les données à chiffrer avec compression
    final compressed = _compressionService.smartCompress(plaintext);

    return _encryptData(
      dataToEncrypt: compressed.data,
      sharedKey: sharedKey,
      isCompressed: compressed.isCompressed,
      contentType: MessageContentType.text,
    );
  }

  /// Chiffre des données binaires (images, fichiers) avec One-Time Pad.
  ///
  /// [data] - Les données binaires à chiffrer
  /// [sharedKey] - La clé partagée à utiliser
  /// [contentType] - Type de contenu (image ou fichier)
  /// [fileName] - Nom du fichier
  /// [mimeType] - Type MIME du fichier
  /// [deleteAfterRead] - Mode ultra-secure, suppression après lecture
  ///
  /// Retourne le message chiffré et l'intervalle utilisé pour mise à jour
  ({EncryptedMessage message, KeyInterval usedSegment}) encryptBinary({
    required Uint8List data,
    required SharedKey sharedKey,
    required MessageContentType contentType,
    String? fileName,
    String? mimeType,
    bool deleteAfterRead = false,
  }) {
    return _encryptData(
      dataToEncrypt: data,
      sharedKey: sharedKey,
      isCompressed: false,
      contentType: contentType,
      fileName: fileName,
      mimeType: mimeType,
    );
  }

  /// Déchiffre un message binaire et retourne les données brutes
  Uint8List decryptBinary({
    required EncryptedMessage encryptedMessage,
    required SharedKey sharedKey,
    bool markAsUsed = true,
  }) {
    return _decryptData(
      encryptedMessage: encryptedMessage,
      sharedKey: sharedKey,
      markAsUsed: markAsUsed,
    );
  }

  /// Déchiffre un message.
  /// 
  /// [encryptedMessage] - Le message chiffré
  /// [sharedKey] - La clé partagée
  /// [markAsUsed] - Si true, marque les octets de clé comme utilisés
  String decrypt({
    required EncryptedMessage encryptedMessage,
    required SharedKey sharedKey,
    bool markAsUsed = true,
  }) {
    // Déchiffrer les données brutes
    final decryptedData = _decryptData(
      encryptedMessage: encryptedMessage,
      sharedKey: sharedKey,
      markAsUsed: markAsUsed,
    );

    // Retourner vide si pas de données
    if (decryptedData.isEmpty) {
      return '';
    }

    // Décompresser si nécessaire
    if (encryptedMessage.isCompressed) {
      return _compressionService.smartDecompress(decryptedData, true);
    } else {
      return utf8.decode(decryptedData);
    }
  }

  /// XOR de deux tableaux d'octets
  Uint8List _xor(Uint8List data, Uint8List key) {
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i];
    }
    return result;
  }

  /// Méthode générique de chiffrement - factorise la logique commune
  /// Retourne le message chiffré et le segment utilisé
  ({EncryptedMessage message, KeyInterval usedSegment}) _encryptData({
    required Uint8List dataToEncrypt,
    required SharedKey sharedKey,
    required bool isCompressed,
    required MessageContentType contentType,
    String? fileName,
    String? mimeType,
  }) {
    final bytesNeeded = dataToEncrypt.length;

    // Trouver un segment disponible en octets
    final seg = sharedKey.findAvailableSegmentByBytes(bytesNeeded);
    if (seg == null) {
      throw InsufficientKeyException(
        'Not enough key bytes available. Needed: $bytesNeeded bytes',
      );
    }
    // Extraire les octets de clé
    final keyBytes = sharedKey.extractKeyBytes(seg.startByte, seg.lengthBytes);
    // XOR des données avec la clé
    final ciphertext = _xor(dataToEncrypt, keyBytes);
    // Créer le message chiffré
    final encryptedMessage = EncryptedMessage(
      id: '${seg.startByte}-${seg.endByte}',
      keyId: sharedKey.id,
      senderId: '', // Sera remplacé dans _postProcessMessage
      keySegment: (startByte: seg.startByte, lengthBytes: seg.lengthBytes),
      ciphertext: ciphertext,
      isCompressed: isCompressed,
      contentType: contentType,
      fileName: fileName,
      mimeType: mimeType,
    );

    return (message: encryptedMessage, usedSegment: seg);
  }

  /// Méthode générique de déchiffrement - factorise la logique commune
  /// Retourne les données déchiffrées brutes
  Uint8List _decryptData({
    required EncryptedMessage encryptedMessage,
    required SharedKey sharedKey,
    required bool markAsUsed,
  }) {
    // Vérifier que la clé correspond
    if (encryptedMessage.keyId != sharedKey.id) {
      throw ArgumentError('Key ID mismatch');
    }

    // Extraire le segment
    final seg = encryptedMessage.keySegment;
    if (seg == null) {
      // Pas chiffré
      return encryptedMessage.ciphertext;
    }

    // Extraire les octets de clé
    final keyBytes = sharedKey.extractKeyBytes(seg.startByte, seg.lengthBytes);

    // XOR pour déchiffrer
    final decryptedData = _xor(encryptedMessage.ciphertext, keyBytes);
    return decryptedData;
  }

  // // TODO change id for message with interval
  // String _generateMessageId() {
  //   String myID = AuthService().currentUserId!;
  //   return 'msg_${DateTime.now().millisecondsSinceEpoch}_$myID';
  // }
}

/// Exception levée quand la clé n'a pas assez de bits disponibles
class InsufficientKeyException implements Exception {
  final String message;
  InsufficientKeyException(this.message);
  
  @override
  String toString() => 'InsufficientKeyException: $message';
}