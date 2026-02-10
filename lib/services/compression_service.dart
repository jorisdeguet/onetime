import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Message compression service before encryption.
///
/// Uses GZIP to compress text messages, which can
/// significantly reduce OTP key consumption.
class CompressionService {

  Uint8List compress(String text) {
    final bytes = utf8.encode(text);
    final compressed = gzip.encode(bytes);
    return Uint8List.fromList(compressed);
  }

  Uint8List decompress(Uint8List compressedData) {
    final decompressed = gzip.decode(compressedData);
    return Uint8List.fromList(decompressed);
  }

  String compressAndDecompress(String text) {
    final compressed = compress(text);
    final decompressed = decompress(compressed);
    return utf8.decode(decompressed);
  }

  double getCompressionRatio(String text) {
    final originalSize = utf8.encode(text).length;
    final compressedSize = compress(text).length;
    return compressedSize / originalSize;
  }

  bool isCompressionBeneficial(String text) {
    return getCompressionRatio(text) < 1.0;
  }

  ({Uint8List data, bool isCompressed}) smartCompress(String text) {
    final original = Uint8List.fromList(utf8.encode(text));
    final compressed = compress(text);

    if (compressed.length < original.length) {
      return (data: compressed, isCompressed: true);
    }
    return (data: original, isCompressed: false);
  }

  String smartDecompress(Uint8List data, bool wasCompressed) {
    if (wasCompressed) {
      return utf8.decode(decompress(data));
    }
    return utf8.decode(data);
  }
}
