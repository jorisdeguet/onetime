import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:onetime/convo/encrypted_message.dart';

import 'app_logger.dart';
import 'format_service.dart';

/// Service pour la gestion des médias (images et fichiers).
class MediaService {
  final ImagePicker _imagePicker = ImagePicker();
  final _log = AppLogger();

  /// Sélectionne une image depuis la galerie ou la caméra
  Future<MediaPickResult?> pickImage({
    required ImageSource source,
    ImageQuality quality = ImageQuality.medium,
  }) async {
    try {
      final XFile? xFile = await _imagePicker.pickImage(
        source: source,
        imageQuality: 100, // Nous gérons la qualité manuellement
      );

      if (xFile == null) return null;

      final bytes = await xFile.readAsBytes();
      final resizedBytes = await _resizeImage(bytes, quality);

      return MediaPickResult(
        data: resizedBytes,
        fileName: xFile.name,
        mimeType: _getMimeType(xFile.name),
        originalSize: bytes.length,
        finalSize: resizedBytes.length,
        contentType: MessageContentType.image,
      );
    } catch (e) {
      _log.e('MediaService', 'Error picking image: $e');
      return null;
    }
  }

  /// Sélectionne un fichier
  Future<MediaPickResult?> pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return null;

      final file = result.files.first;
      if (file.bytes == null) {
        // Lire depuis le path si les bytes ne sont pas disponibles
        if (file.path != null) {
          final bytes = await File(file.path!).readAsBytes();
          return MediaPickResult(
            data: bytes,
            fileName: file.name,
            mimeType: _getMimeType(file.name),
            originalSize: bytes.length,
            finalSize: bytes.length,
            contentType: MessageContentType.file,
          );
        }
        return null;
      }

      return MediaPickResult(
        data: file.bytes!,
        fileName: file.name,
        mimeType: _getMimeType(file.name),
        originalSize: file.bytes!.length,
        finalSize: file.bytes!.length,
        contentType: MessageContentType.file,
      );
    } catch (e) {
      _log.e('MediaService', 'Error picking file: $e');
      return null;
    }
  }

  /// Redimensionne une image selon la qualité demandée
  Future<Uint8List> _resizeImage(Uint8List bytes, ImageQuality quality) async {
    if (quality == ImageQuality.original) {
      return bytes;
    }

    return compute(_resizeImageIsolate, _ResizeParams(bytes, quality.maxDimension));
  }

  /// Fonction isolée pour le redimensionnement d'image
  static Uint8List _resizeImageIsolate(_ResizeParams params) {
    final image = img.decodeImage(params.bytes);
    if (image == null) return params.bytes;

    // Calculer les nouvelles dimensions
    int newWidth = image.width;
    int newHeight = image.height;

    if (image.width > params.maxDimension || image.height > params.maxDimension) {
      if (image.width > image.height) {
        newWidth = params.maxDimension;
        newHeight = (image.height * params.maxDimension / image.width).round();
      } else {
        newHeight = params.maxDimension;
        newWidth = (image.width * params.maxDimension / image.height).round();
      }
    }

    // Redimensionner si nécessaire
    final resized = (newWidth != image.width || newHeight != image.height)
        ? img.copyResize(image, width: newWidth, height: newHeight)
        : image;

    // Encoder en JPEG avec compression
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }

  /// Obtient le type MIME d'un fichier
  String _getMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'txt':
        return 'text/plain';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  /// Calcule l'estimation des bits de clé nécessaires pour un média
  int estimateKeyBitsNeeded(int dataSize) {
    return dataSize * 8;
  }

  /// Formate la taille en format lisible
  String formatSize(int bytes) {
    return FormatService.formatBytes(bytes);
  }

  /// Formate les bits de clé en format lisible
  String formatKeyBits(int bits) {
    final bytes = bits ~/ 8;
    return formatSize(bytes);
  }
}

/// Paramètres pour le redimensionnement isolé
class _ResizeParams {
  final Uint8List bytes;
  final int maxDimension;

  _ResizeParams(this.bytes, this.maxDimension);
}

/// Résultat de la sélection d'un média
class MediaPickResult {
  final Uint8List data;
  final String fileName;
  final String mimeType;
  final int originalSize;
  final int finalSize;
  final MessageContentType contentType;

  MediaPickResult({
    required this.data,
    required this.fileName,
    required this.mimeType,
    required this.originalSize,
    required this.finalSize,
    required this.contentType,
  });

  /// Bits de clé nécessaires pour chiffrer ce média
  int get bitsNeeded => data.length * 8;

  /// Le fichier a-t-il été compressé/redimensionné ?
  bool get wasResized => originalSize != finalSize;

  /// Pourcentage de compression
  double get compressionPercent =>
      wasResized ? ((originalSize - finalSize) / originalSize) * 100 : 0;
}
