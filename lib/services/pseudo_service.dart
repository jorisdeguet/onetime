import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/local/local_pseudo.dart';
import 'app_logger.dart';

/// Service to manage user pseudonyms.
/// Uses a local JSON file for storage.
///
/// Storage structure:
/// ```
/// <app_documents>/pseudos.json
/// ```
class PseudoService {
  static const String _fileName = 'pseudos.json';

  final _pseudoUpdateController = StreamController<String>.broadcast();
  Stream<String> get pseudoUpdates => _pseudoUpdateController.stream;

  /// In-memory cache
  LocalPseudo? _cache;
  bool _isLoaded = false;

  final _log = AppLogger();
  File? _file;

  /// Gets the pseudos file
  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final appDir = await getApplicationDocumentsDirectory();
    _file = File(path.join(appDir.path, _fileName));
    return _file!;
  }

  /// Loads data from file
  Future<void> _loadFromFile() async {
    if (_isLoaded) return;
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(content);
        _cache = LocalPseudo.fromJson(data);
      } else {
        _cache = LocalPseudo();
      }
      _isLoaded = true;
    } catch (e) {
      _log.e('PseudoService', 'Error loading pseudos file: $e');
      _cache = LocalPseudo();
      _isLoaded = true;
    }
  }

  /// Saves data to file
  Future<void> _saveToFile() async {
    if (_cache == null) return;
    try {
      final file = await _getFile();
      final jsonStr = jsonEncode(_cache!.toJson());
      // Atomic write via temporary file
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonStr, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    } catch (e) {
      _log.e('PseudoService', 'Error saving pseudos file: $e');
      rethrow;
    }
  }

  Future<String?> getMyPseudo() async {
    await _loadFromFile();
    return _cache?.myPseudo;
  }

  Future<void> setMyPseudo(String pseudo) async {
    await _loadFromFile();
    _cache = _cache!.copyWith(myPseudo: pseudo);
    await _saveToFile();
    _log.i('PseudoService', 'My pseudo set: $pseudo');
  }

  /// Gets a user's pseudo by ID
  Future<String?> getPseudo(String oderId) async {
    await _loadFromFile();
    return _cache?.pseudos[oderId];
  }

  /// Sets a user's pseudo
  Future<void> setPseudo(String userID, String pseudo) async {
    await _loadFromFile();
    if (_cache!.pseudos[userID] == pseudo) {
      return;
    }
    final updatedPseudos = Map<String, String>.from(_cache!.pseudos);
    updatedPseudos[userID] = pseudo;
    _cache = _cache!.copyWith(pseudos: updatedPseudos);
    await _saveToFile();
    _pseudoUpdateController.add("update");
    _log.i('PseudoService', 'Pseudo set for $userID: $pseudo');
  }

  /// Sets multiple pseudos at once
  Future<void> setPseudos(Map<String, String> pseudos) async {
    await _loadFromFile();
    final updatedPseudos = Map<String, String>.from(_cache!.pseudos);
    updatedPseudos.addAll(pseudos);
    _cache = _cache!.copyWith(pseudos: updatedPseudos);
    await _saveToFile();
    _log.i('PseudoService', 'Pseudos set: ${pseudos.keys.join(", ")}');
    _pseudoUpdateController.add("update");
  }

  /// Removes a user's pseudo
  Future<void> removePseudo(String oderId) async {
    await _loadFromFile();
    final updatedPseudos = Map<String, String>.from(_cache!.pseudos);
    updatedPseudos.remove(oderId);
    _cache = _cache!.copyWith(pseudos: updatedPseudos);
    await _saveToFile();
  }

  /// Returns a display name for a user ID
  /// If a pseudo is known, returns it, otherwise returns a short version of the ID
  Future<String> getDisplayName(String userId) async {
    final pseudo = await getPseudo(userId);
    if (pseudo != null && pseudo.isNotEmpty) {
      return pseudo;
    }
    // Return last digits of ID
    if (userId.length > 4) {
      return '...${userId.substring(userId.length - 4)}';
    }
    return userId;
  }

  Future<Map<String, String>> getPseudos(List<String> oderIds) async {
    return getDisplayNames(oderIds);
  }

  /// Returns display names for multiple IDs
  Future<Map<String, String>> getDisplayNames(List<String> oderIds) async {
    await _loadFromFile();
    final pseudos = _cache?.pseudos ?? {};
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

  /// Clears the in-memory cache (to force a reload)
  void clearCache() {
    _cache = null;
    _isLoaded = false;
  }

  /// Closes the internal stream controller.
  /// Call this only when the app is shutting down.
  void dispose() {
    if (!_pseudoUpdateController.isClosed) {
      _pseudoUpdateController.close();
    }
  }
}
