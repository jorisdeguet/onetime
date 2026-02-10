import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:onetime/services/key_storage.dart';

import '../models/local/shared_key.dart';

class KeyService {
  static const int segmentSizeBytes = 1024;

  final _keyStorage = KeyStorage.instance;

  KeyService();

  Future<SharedKey> getKey(String conversationId) async
    => _keyStorage.getKey(conversationId);

  Future<void> updateUsedBytes(String conversationId, int startByte, int endByte) async
    => _keyStorage.updateUsedBytes(conversationId, startByte, endByte);

  KexSessionSource createSourceSession({
    required String conversationId,
    required int totalBytes,
    required List<String> peerIds,
    required String sourceId,
    String? sessionId,
    List<KeySegmentQrData>? preGeneratedSegments,
  }) {
    // Inclure le source dans la liste des peers
    final allPeers = [sourceId, ...peerIds]..sort();

    final session = KexSessionSource(
      conversationId: conversationId,
      sessionId: sessionId ?? _generateSessionId(),
      role: KeyExchangeRole.source,
      peerIds: allPeers,
      localPeerId: sourceId,
      totalBytes: totalBytes,
    );

    // Injecter les segments pré-générés si disponibles
    if (preGeneratedSegments != null) {
      for (final segment in preGeneratedSegments) {
        // Attention: il faut s'assurer que l'ID de session correspond
        // Si les segments viennent d'une pré-génération avec un ID différent,
        // on doit recréer le QR data avec le bon ID de session final
        if (segment.sessionId != session.sessionId) {
          // On garde les données de clé mais on met à jour l'ID de session
          final updatedSegment = KeySegmentQrData(
            sessionId: session.sessionId,
            segmentIndex: segment.segmentIndex,
            startByte: segment.startByte,
            endByte: segment.endByte,
            keyData: segment.keyData,
          );
          // On injecte directement dans la session sans régénérer
          _injectSegmentIntoSession(session, updatedSegment);
        } else {
          _injectSegmentIntoSession(session, segment);
        }
      }
    }

    return session;
  }

  // Get the total key storage used bytes for this user
  Future<int> getTotalKeyStorageUsedBytes() async {
    return _keyStorage.getTotalUsedBytes();
  }

  /// Injecte un segment manuellement dans la session (usage interne pour pré-génération)
  void _injectSegmentIntoSession(KexSessionReader session, KeySegmentQrData segment) {
    session.addSegmentData(segment.startByte, segment.keyData);
  }

  /// Crée une session d'échange de clé (côté lecteur).
  ///
  /// [sessionId] - ID de la session partagé par la source
  /// [localPeerId] - ID local de ce lecteur
  KexSessionReader createReaderSession({
    required String conversationId,
    required String sessionId,
    required String localPeerId,
    required List<String> peerIds,
  }) {
    return KexSessionReader(
      conversationId: conversationId,
      sessionId: sessionId,
      role: KeyExchangeRole.reader,
      peerIds: peerIds,
      localPeerId: localPeerId,
    );
  }

  /// Génère le prochain segment de clé à afficher (côté source).
  KeySegmentQrData generateNextSegment(KexSessionReader session) {
    if (session.role != KeyExchangeRole.source) {
      throw StateError('Only source can generate segments');
    }

    // Cast sécurisé vers KexSessionSource pour accéder à totalBytes
    if (session is! KexSessionSource) {
      throw StateError('Session must be KexSessionSource to generate segments');
    }
    final src = session;

    // Capturer l'index AVANT de modifier la session
    final segmentIndex = session.currentSegmentIndex;
    final startByte = segmentIndex * segmentSizeBytes;
    final endByte = (startByte + segmentSizeBytes) < src.totalBytes ? (startByte + segmentSizeBytes) : src.totalBytes;

    if (startByte >= src.totalBytes) {
      throw StateError('All segments have been generated');
    }

    // Générer les octets aléatoires pour ce segment
    final segmentBytes = endByte - startByte;
    final keyData = _generateRandomBytes(segmentBytes); // generator expects bits

    // Stocker le segment dans la session (ceci incrémente currentSegmentIndex)
    session.addSegmentData(startByte, keyData);

    return KeySegmentQrData(
      sessionId: session.sessionId,
      segmentIndex: segmentIndex, // Utiliser l'index capturé avant l'incrémentation
      startByte: startByte,
      endByte: endByte,
      keyData: keyData,
    );
  }

  /// Parse un QR code contenant un segment de clé (côté lecteur).
  KeySegmentQrData parseQrCode(String qrData) {
    return KeySegmentQrData.fromQrString(qrData);
  }

  /// Enregistre un segment lu depuis un QR code (côté lecteur).
  void recordReadSegment(KexSessionReader session, KeySegmentQrData segment) {
    if (session.role != KeyExchangeRole.reader) {
      throw StateError('Only readers record segments');
    }

    session.addSegmentData(segment.startByte, segment.keyData);
    session.markSegmentAsRead(segment.segmentIndex);
  }

  /// Génère la confirmation d'un segment lu.
  /// Contient SEULEMENT l'index, jamais les octets de clé.
  KeySegmentConfirmation createReadConfirmation(
      KexSessionReader session,
      int segmentIndex,
      ) {
    return KeySegmentConfirmation(
      sessionId: session.sessionId,
      peerId: session.localPeerId,
      segmentIndex: segmentIndex,
      timestamp: DateTime.now(),
    );
  }

  /// Enregistre une confirmation reçue d'un lecteur (côté source).
  void recordConfirmation(
      KexSessionSource session,
      KeySegmentConfirmation confirmation,
      ) {
    session.markPeerHasSegment(confirmation.peerId, confirmation.segmentIndex);
  }

  /// Vérifie si tous les peers ont lu tous les segments.
  bool isExchangeComplete(KexSessionSource session) {
    return session.isComplete;
  }

  /// Finalise l'échange et crée la clé partagée.
  /// [force] permet de forcer la finalisation même si tous les peers n'ont pas confirmé localement
  /// (utile quand la vérification est faite via Firestore)
  SharedKey finalizeExchange(KexSessionReader session, {bool force = false}) {
    // Si c'est une source et qu'on ne force pas, vérifier l'état
    if (!force && session is KexSessionSource && session.role == KeyExchangeRole.source && !session.isComplete) {
      throw StateError('Exchange is not complete, not all peers confirmed');
    }

    return session.buildSharedKey();
  }

  /// Permet d'agrandir une clé existante avec de nouveaux segments.
  KeyExtensionSession createExtensionSession({
    required SharedKey existingKey,
    required int additionalBits,
  }) {
    return KeyExtensionSession(
      sessionId: _generateSessionId(),
      existingKey: existingKey,
      additionalBits: additionalBits,
    );
  }

  String _generateSessionId() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'session_$random';
  }

  Uint8List _generateRandomBytes(int byteCount) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  Future<List<String>> listConversations() async =>
      _keyStorage.listConversationsWithKeys();

  Future<void> deleteKey(String convId) async =>
      _keyStorage.deleteKey(convId);

  Future<void> saveKey(String conversationId, SharedKey finalKey) async {
    return _keyStorage.saveKey(conversationId, finalKey);
  }

}

/// Source shows QR codes, reader scans them
enum KeyExchangeRole { source,reader, }

class KexSessionReader {
  final String conversationId;
  final String sessionId;
  final KeyExchangeRole role;
  final List<String> peerIds;
  final String localPeerId;
  
  /// Segments de clé déjà générés/lus (index -> données)
  final Map<int, Uint8List> _segmentData = {};
  
  /// Segments lus par chaque peer (peerId -> set de segmentIndex)
  final Map<String, Set<int>> _peerReadSegments = {};
  
  /// Index du segment courant (côté source)
  int _currentSegmentIndex = 0;

  KexSessionReader({
    required this.conversationId,
    required this.sessionId,
    required this.role,
    required this.peerIds,
    required this.localPeerId,
  }) {
    for (final peer in peerIds) {
      _peerReadSegments[peer] = {};
    }
  }

  int get currentSegmentIndex => _currentSegmentIndex;
  
  /// Nombre de segments lus (pour le reader)
  int get readSegmentsCount => _peerReadSegments[localPeerId]?.length ?? 0;

  /// Accède aux données d'un segment par son index (pour le mode torrent)
  Uint8List? getSegmentData(int segmentIndex) => _segmentData[segmentIndex];

  void addSegmentData(int startByte, Uint8List data) {
    final segmentIndex = startByte ~/ KeyService.segmentSizeBytes;
    _segmentData[segmentIndex] = data;
    if (role == KeyExchangeRole.source) {
      _currentSegmentIndex = segmentIndex + 1;
      // La source a automatiquement tous les segments qu'elle génère
      _peerReadSegments[localPeerId]?.add(segmentIndex);
    }
  }

  void markSegmentAsRead(int segmentIndex) {
    _peerReadSegments[localPeerId]?.add(segmentIndex);
    // Pour le reader, mettre à jour currentSegmentIndex
    if (role == KeyExchangeRole.reader) {
      _currentSegmentIndex = _peerReadSegments[localPeerId]?.length ?? 0;
    }
  }

  /// Vérifie si le participant local a déjà scanné un segment donné
  bool hasScannedSegment(int segmentIndex) {
    return _peerReadSegments[localPeerId]?.contains(segmentIndex) ?? false;
  }

  void markPeerHasSegment(String peerId, int segmentIndex) {
    _peerReadSegments[peerId]?.add(segmentIndex);
  }

  /// Construit la clé partagée finale (fonctionne pour reader et source)
  SharedKey buildSharedKey() {
    // Assembler tous les segments dans l'ordre
    final sortedIndexes = _segmentData.keys.toList()..sort();

    // Calculer la taille totale
    int totalBytes = 0;
    for (final index in sortedIndexes) {
      totalBytes += _segmentData[index]!.length;
    }

    // Assembler la clé
    final keyData = Uint8List(totalBytes);
    int offset = 0;
    for (final index in sortedIndexes) {
      final segment = _segmentData[index]!;
      keyData.setRange(offset, offset + segment.length, segment);
      offset += segment.length;
    }

    return SharedKey(
      id: conversationId,
      keyData: keyData,
      peerIds: List.from(peerIds),
      nextAvailableByte: 0
    );
  }

  int get totalSegments => _segmentData.length;
}

/// Session côté source avec informations supplémentaires
class KexSessionSource extends KexSessionReader {
  final int totalBytes;

  KexSessionSource({
    required super.conversationId,
    required super.sessionId,
    required super.role,
    required super.peerIds,
    required super.localPeerId,
    required this.totalBytes,
  });

  @override
  int get totalSegments => (totalBytes + KeyService.segmentSizeBytes - 1) ~/
                           KeyService.segmentSizeBytes;

  /// Vérifie si l'échange est complet
  bool get isComplete {
    for (final peer in peerIds) {
      final readSegments = _peerReadSegments[peer] ?? {};
      if (readSegments.length < totalSegments) {
        return false;
      }
    }
    return true;
  }
}

/// Données d'un segment de clé pour QR code
class KeySegmentQrData {
  final String sessionId;
  final int segmentIndex;
  final int startByte;
  final int endByte;
  final Uint8List keyData;

  KeySegmentQrData({
    required this.sessionId,
    required this.segmentIndex,
    required this.startByte,
    required this.endByte,
    required this.keyData,
  }){
  }

  /// Convertit en chaîne pour QR code
  String toQrString() {
    final json = {
      's': sessionId,
      'i': segmentIndex,
      'a': startByte,
      'b': endByte,
      'k': base64Encode(keyData),
    };
    return jsonEncode(json);
  }

  /// Parse depuis une chaîne QR
  factory KeySegmentQrData.fromQrString(String qrString) {
    final json = jsonDecode(qrString) as Map<String, dynamic>;
    return KeySegmentQrData(
      sessionId: json['s'] as String,
      segmentIndex: json['i'] as int,
      startByte: json['a'] as int,
      endByte: json['b'] as int,
      keyData: base64Decode(json['k'] as String),
    );
  }

  /// Taille estimée en caractères pour le QR
  int get estimatedQrSize => toQrString().length;
}

/// Confirmation de lecture d'un segment (envoyée sur le réseau)
class KeySegmentConfirmation {
  final String sessionId;
  final String peerId;
  final int segmentIndex;
  final DateTime timestamp;

  KeySegmentConfirmation({
    required this.sessionId,
    required this.peerId,
    required this.segmentIndex,
    required this.timestamp,
  }) {
  }

  /// Sérialise pour envoi réseau (NE CONTIENT PAS les octets de clé)
  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'peerId': peerId,
      'segmentIndex': segmentIndex,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory KeySegmentConfirmation.fromJson(Map<String, dynamic> json) {
    return KeySegmentConfirmation(
      sessionId: json['sessionId'] as String,
      peerId: json['peerId'] as String,
      segmentIndex: json['segmentIndex'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

/// Session d'extension de clé existante
class KeyExtensionSession {
  final String sessionId;
  final SharedKey existingKey;
  final int additionalBits;
  final List<Uint8List> newSegments = [];

  KeyExtensionSession({
    required this.sessionId,
    required this.existingKey,
    required this.additionalBits,
  });

  /// Ajoute un nouveau segment
  void addSegment(Uint8List segment) {
    newSegments.add(segment);
  }

  /// Vérifie si assez de bits ont été ajoutés
  bool get isComplete {
    int totalNewBits = 0;
    for (final seg in newSegments) {
      totalNewBits += seg.length * 8;
    }
    return totalNewBits >= additionalBits;
  }

  /// Crée la clé étendue
  SharedKey buildExtendedKey() {
    // Concaténer tous les nouveaux segments
    int totalNewBytes = 0;
    for (final seg in newSegments) {
      totalNewBytes += seg.length;
    }
    
    final additionalData = Uint8List(totalNewBytes);
    int offset = 0;
    for (final seg in newSegments) {
      additionalData.setRange(offset, offset + seg.length, seg);
      offset += seg.length;
    }
    
    return existingKey.extend(additionalData);
  }
}
