import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_logger.dart';


class PseudoService {
  static const String _pseudosKey = 'local_pseudos';
  static const String _myPseudoKey = 'my_pseudo';

  final _pseudoUpdateController = StreamController<String>.broadcast();
  Stream<String> get pseudoUpdates => _pseudoUpdateController.stream;

  /// Cache en mémoire des pseudos
  Map<String, String>? _pseudosCache;
  final _log = AppLogger();

  Future<String?> getMyPseudo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_myPseudoKey);
  }

  Future<void> setMyPseudo(String pseudo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_myPseudoKey, pseudo);
    _log.i('PseudoStorage', 'My pseudo set: $pseudo');
  }

  /// Charge tous les pseudos depuis le stockage local
  Future<Map<String, String>> _loadPseudos() async {
    if (_pseudosCache != null) return _pseudosCache!;

    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_pseudosKey);

    if (jsonStr == null) {
      _pseudosCache = {};
      return _pseudosCache!;
    }

    try {
      final Map<String, dynamic> decoded = jsonDecode(jsonStr);
      _pseudosCache = decoded.map((k, v) => MapEntry(k, v.toString()));
      return _pseudosCache!;
    } catch (e) {
      _log.e('PseudoStorage', 'Error loading pseudos: $e');
      _pseudosCache = {};
      return _pseudosCache!;
    }
  }

  /// Sauvegarde tous les pseudos
  Future<void> _savePseudos() async {
    if (_pseudosCache == null) return;

    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(_pseudosCache);
    await prefs.setString(_pseudosKey, jsonStr);
  }

  /// Récupère le pseudo d'un utilisateur par son ID
  Future<String?> getPseudo(String oderId) async {
    final pseudos = await _loadPseudos();
    return pseudos[oderId];
  }

  /// Définit le pseudo d'un utilisateur
  Future<void> setPseudo(String userID, String pseudo) async {
    await _loadPseudos();
    if (_pseudosCache![userID] == pseudo) {
      return;
    }
    _pseudosCache![userID] = pseudo;
    await _savePseudos();
    _pseudoUpdateController.add("update");
    _log.i('PseudoStorage', 'Pseudo set for $userID: $pseudo');
  }

  /// Définit plusieurs pseudos en une fois
  Future<void> setPseudos(Map<String, String> pseudos) async {
    await _loadPseudos();
    _pseudosCache!.addAll(pseudos);
    await _savePseudos();
    _log.i('PseudoStorage', 'Pseudos set: ${pseudos.keys.join(", ")}');
    _pseudoUpdateController.add("update");
  }

  /// Supprime le pseudo d'un utilisateur
  Future<void> removePseudo(String oderId) async {
    await _loadPseudos();
    _pseudosCache!.remove(oderId);
    await _savePseudos();
  }

  /// Retourne un nom d'affichage pour un ID utilisateur
  /// Si un pseudo est connu, le retourne, sinon retourne une version courte de l'ID
  Future<String> getDisplayName(String userId) async {
    final pseudo = await getPseudo(userId);
    if (pseudo != null && pseudo.isNotEmpty) {
      return pseudo;
    }
    // Retourner les derniers chiffres du numéro de téléphone
    if (userId.length > 4) {
      return '...${userId.substring(userId.length - 4)}';
    }
    return userId;
  }

  Future<Map<String, String>> getPseudos(List<String> oderIds) async {
    return getDisplayNames(oderIds);
  }

  /// Retourne les noms d'affichage pour plusieurs IDs
  Future<Map<String, String>> getDisplayNames(List<String> oderIds) async {
    final pseudos = await _loadPseudos();
    final result = <String, String>{};

    for (final oderId in oderIds) {
      if (pseudos.containsKey(oderId) && pseudos[oderId]!.isNotEmpty) {
        result[oderId] = pseudos[oderId]!;
      } else if (oderId.length > 4) {
        result[oderId] = '...${oderId.substring(oderId.length - 4)}';
      } else {
        result[oderId] = oderId;
      }
    }

    return result;
  }

  /// Efface le cache en mémoire (pour forcer un rechargement)
  void clearCache() {
    _pseudosCache = null;
  }

  /// Optionally expose a way to close the internal stream controller.
  /// Call this only when the app is shutting down (rare in Flutter mobile apps).
  void dispose() {
    if (!_pseudoUpdateController.isClosed) {
      _pseudoUpdateController.close();
    }
  }
}

