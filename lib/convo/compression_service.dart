import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Service de compression des messages avant chiffrement.
/// 
/// Utilise GZIP pour compresser les messages texte, ce qui peut
/// réduire significativement la consommation de clé OTP.
class CompressionService {
  /// Compresse une chaîne de caractères.
  /// 
  /// Retourne les données compressées en bytes.
  Uint8List compress(String text) {
    final bytes = utf8.encode(text);
    final compressed = gzip.encode(bytes);
    return Uint8List.fromList(compressed);
  }

  /// Décompresse des données en chaîne de caractères.
  Uint8List decompress(Uint8List compressedData) {
    final decompressed = gzip.decode(compressedData);
    return Uint8List.fromList(decompressed);
  }

  /// Compresse et retourne le texte décompressé (pour vérification).
  String compressAndDecompress(String text) {
    final compressed = compress(text);
    final decompressed = decompress(compressed);
    return utf8.decode(decompressed);
  }

  /// Calcule le ratio de compression pour un texte.
  /// 
  /// Retourne un ratio < 1 si la compression est efficace.
  /// Exemple: 0.5 = 50% de la taille originale.
  double getCompressionRatio(String text) {
    final originalSize = utf8.encode(text).length;
    final compressedSize = compress(text).length;
    return compressedSize / originalSize;
  }

  /// Vérifie si la compression est bénéfique pour un texte.
  /// 
  /// La compression GZIP a un overhead, donc pour les très courts
  /// messages, elle peut augmenter la taille.
  bool isCompressionBeneficial(String text) {
    return getCompressionRatio(text) < 1.0;
  }

  /// Compresse uniquement si bénéfique, sinon retourne les bytes originaux.
  /// 
  /// Retourne un tuple (données, estCompressé).
  ({Uint8List data, bool isCompressed}) smartCompress(String text) {
    final original = Uint8List.fromList(utf8.encode(text));
    final compressed = compress(text);
    
    if (compressed.length < original.length) {
      return (data: compressed, isCompressed: true);
    }
    return (data: original, isCompressed: false);
  }

  /// Décompresse si les données étaient compressées.
  String smartDecompress(Uint8List data, bool wasCompressed) {
    if (wasCompressed) {
      return utf8.decode(decompress(data));
    }
    return utf8.decode(data);
  }
}

