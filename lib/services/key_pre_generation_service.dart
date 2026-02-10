import 'dart:async';

import 'package:onetime/services/key_service.dart';

import 'app_logger.dart';

/// Service responsible for pre-generating key data
/// to speed up the exchange startup.
class KeyPreGenerationService {
  static final KeyPreGenerationService _instance = KeyPreGenerationService._internal();
  factory KeyPreGenerationService() => _instance;
  KeyPreGenerationService._internal();

  late final KeyService _keyService = KeyService();
  final _log = AppLogger();

  // Pool de sessions pré-générées
  // Clé: taille de la clé en octets (ex: 8192)
  final Map<int, _PreGeneratedSession> _preGeneratedPool = {};
  
  bool _isGenerating = false;

  // Nombre de segments cibles à avoir prêts (30 segments)
  static const int _targetReadySegments = 30;

  /// Initialise le service et commence la pré-génération
  void initialize() {
    _log.i('KeyPreGen', 'Initializing service...');
    // Démarrer la génération en arrière-plan sans bloquer
    Future.delayed(const Duration(seconds: 2), _replenishPool);
  }

  /// Récupère une session pré-générée si disponible
  /// Retourne null si aucune session n'est prête
  _PreGeneratedSession? consumeSession(int totalBytes) {
    if (_preGeneratedPool.containsKey(totalBytes)) {
      final session = _preGeneratedPool.remove(totalBytes);
      _log.i('KeyPreGen', 'Consumed session ${session?.sessionId} for $totalBytes bytes');

      // Déclencher le remplissage du pool
      _triggerReplenish();
      
      return session;
    }
    return null;
  }

  void _triggerReplenish() {
    if (!_isGenerating) {
      // Attendre un peu pour ne pas impacter les performances immédiates
      Future.delayed(const Duration(seconds: 5), _replenishPool);
    }
  }

  Future<void> _replenishPool() async {
    if (_isGenerating) return;
    _isGenerating = true;

    try {

        if (!_preGeneratedPool.containsKey(8192)) {
          _log.i('KeyPreGen', 'Generating session for 8192 bytes...');

          final session = await _generateSession(8192);
          _preGeneratedPool[8192] = session;
          
          _log.i('KeyPreGen', 'Session ready for 8192 bytes (${session.preGeneratedSegments.length} segments)');

          // Yield to main thread
          await Future.delayed(Duration.zero);
      }
    } catch (e) {
      _log.e('KeyPreGen', 'Error generating session: $e');
    } finally {
      _isGenerating = false;
    }
  }

  Future<_PreGeneratedSession> _generateSession(int totalBytes) async {
    final sessionId = 'pre_${DateTime.now().millisecondsSinceEpoch}';
    
    // Créer une session temporaire pour utiliser la logique de génération existante
    // On met des IDs bidons car ils seront remplacés lors de l'utilisation réelle
    final tempSession = KexSessionSource(
      conversationId: 'placeholder',
      sessionId: sessionId,
      role: KeyExchangeRole.source,
      peerIds: ['placeholder'],
      localPeerId: 'source_placeholder',
      totalBytes: totalBytes,
    );

    final segments = <KeySegmentQrData>[];
    
    // Générer les N premiers segments
    for (int i = 0; i < _targetReadySegments; i++) {
      if (i * KeyService.segmentSizeBytes >= totalBytes) break;

      final segment = _keyService.generateNextSegment(tempSession);
      segments.add(segment);
      
      // Yield pour ne pas bloquer l'UI
      if (i % 5 == 0) await Future.delayed(Duration.zero);
    }

    return _PreGeneratedSession(
      sessionId: sessionId,
      totalBytes: totalBytes,
      preGeneratedSegments: segments,
    );
  }
}

class _PreGeneratedSession {
  final String sessionId;
  final int totalBytes;
  final List<KeySegmentQrData> preGeneratedSegments;

  _PreGeneratedSession({
    required this.sessionId,
    required this.totalBytes,
    required this.preGeneratedSegments,
  });
}
