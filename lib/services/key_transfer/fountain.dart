import 'dart:convert';
import 'dart:typed_data';

import 'base45.dart';

/// One QR code of a fountain-coded key transfer.
///
/// The key is cut into symbols of [symbolSize] bytes (the last one zero
/// padded), grouped into blocks of [blockSymbols]. Packet [index] of a block
/// is either the symbol itself (index < symbols in the block, "systematic")
/// or a repair packet: the XOR of a pseudo-random subset of the block's
/// symbols, derived from (block, index). A reader rebuilds a block from any
/// set of packets of that block spanning all its symbols — in practice the
/// symbols it scanned plus about as many repair packets as it missed.
class FountainPacket {
  final String sessionId;
  final int totalBytes;
  final int symbolSize;
  final int blockSymbols;
  final int block;
  final int index;
  final Uint8List data;

  FountainPacket({
    required this.sessionId,
    required this.totalBytes,
    required this.symbolSize,
    required this.blockSymbols,
    required this.block,
    required this.index,
    required this.data,
  });

  int get symbolCount => (totalBytes + symbolSize - 1) ~/ symbolSize;
  int get blockCount => (symbolCount + blockSymbols - 1) ~/ blockSymbols;
}

/// Shared parameters of a transfer and the mixing rule both sides follow.
class FountainLayout {
  final int totalBytes;
  final int symbolSize;
  final int blockSymbols;

  const FountainLayout({required this.totalBytes, required this.symbolSize, this.blockSymbols = 32})
      : assert(blockSymbols >= 1 && blockSymbols <= 32);

  int get symbolCount => (totalBytes + symbolSize - 1) ~/ symbolSize;
  int get blockCount => (symbolCount + blockSymbols - 1) ~/ blockSymbols;
  int firstSymbol(int block) => block * blockSymbols;
  int symbolsInBlock(int block) {
    final remaining = symbolCount - firstSymbol(block);
    return remaining < blockSymbols ? remaining : blockSymbols;
  }

  /// Bit i set when symbol i of the block is part of packet [index].
  int mask(int block, int index) {
    final k = symbolsInBlock(block);
    if (index < k) return 1 << index;
    final all = k == 32 ? 0xFFFFFFFF : (1 << k) - 1;
    // xorshift32 seeded from (block, index); retried until the subset is not empty
    int x = (block * 0x9E3779B1 ^ index * 0x85EBCA77 ^ 0x2545F491) & 0xFFFFFFFF;
    while (true) {
      x ^= (x << 13) & 0xFFFFFFFF;
      x ^= x >> 17;
      x ^= (x << 5) & 0xFFFFFFFF;
      final m = x & all;
      if (m != 0) return m;
    }
  }
}

/// Produces packets from the key symbols, in the order they should be shown:
/// every symbol once, then repair packets for the blocks still incomplete.
/// While symbols are still being shown, some packets repair earlier blocks
/// someone still misses, so a long (continuous) transfer does not leave gaps
/// until its very end: one in 4 while few blocks lag behind, up to one in 2
/// as the backlog grows (a reader missing a quarter of the codes needs at
/// least that many repairs to keep up).
class FountainEncoder {
  final FountainLayout layout;
  final String sessionId;
  final Uint8List? Function(int symbol) symbolAt;
  int _nextSystematic = 0;
  int _repairCursor = 0;
  int _packets = 0;
  late final List<int> _repairsSent = List.filled(layout.blockCount, 0);

  /// Most recent blocks not counted as lagging yet: their acknowledgements
  /// may still be on their way (a radio link sends ahead of its acks).
  final int ackLagBlocks;

  FountainEncoder({required this.layout, required this.sessionId, required this.symbolAt, this.ackLagBlocks = 0});

  /// Symbols shown at least once so far.
  int get symbolsShown => _nextSystematic;

  /// Next packet to show, skipping blocks [isBlockDone] reports as received
  /// by everyone; null when every block is done or the next symbol is not
  /// generated yet.
  FountainPacket? next(bool Function(int block) isBlockDone) {
    _packets++;
    if (_nextSystematic < layout.symbolCount) {
      // Blocks whose symbols were all shown already, and how many lag behind
      final shownBlocks = (_nextSystematic ~/ layout.blockSymbols - ackLagBlocks).clamp(0, layout.blockCount);
      int lagging = 0;
      for (int b = 0; b < shownBlocks; b++) {
        if (!isBlockDone(b)) lagging++;
      }
      final repairEvery = lagging == 0 ? 0 : lagging <= 2 ? 4 : lagging <= 4 ? 3 : 2;
      if (repairEvery > 0 && _packets % repairEvery == 0) {
        // Only the prefix everyone holds is kept: every other repair goes to
        // the first lagging block, the others take turns
        final repair = _packets % (2 * repairEvery) == 0
            ? _repairFirst(isBlockDone, shownBlocks)
            : _repair(isBlockDone, shownBlocks);
        if (repair != null) return repair;
      }
    }
    while (_nextSystematic < layout.symbolCount) {
      final symbol = _nextSystematic;
      final block = symbol ~/ layout.blockSymbols;
      if (isBlockDone(block)) {
        _nextSystematic++;
        continue;
      }
      final packet = this.packet(block, symbol - layout.firstSymbol(block));
      if (packet != null) _nextSystematic++;
      return packet;
    }
    return _repair(isBlockDone, layout.blockCount);
  }

  /// Repair packet for the first incomplete block among the first [blocks].
  FountainPacket? _repairFirst(bool Function(int block) isBlockDone, int blocks) {
    for (int block = 0; block < blocks; block++) {
      if (isBlockDone(block)) continue;
      final index = layout.symbolsInBlock(block) + _repairsSent[block]++;
      return packet(block, index);
    }
    return null;
  }

  /// Repair packet for the next incomplete block among the first [blocks].
  FountainPacket? _repair(bool Function(int block) isBlockDone, int blocks) {
    for (int tries = 0; tries < blocks; tries++) {
      final block = _repairCursor % blocks;
      _repairCursor = block + 1;
      if (isBlockDone(block)) continue;
      final index = layout.symbolsInBlock(block) + _repairsSent[block]++;
      return packet(block, index);
    }
    return null;
  }

  FountainPacket? packet(int block, int index) {
    final mask = layout.mask(block, index);
    final data = Uint8List(layout.symbolSize);
    for (int i = 0; i < layout.symbolsInBlock(block); i++) {
      if (mask & (1 << i) == 0) continue;
      final symbol = symbolAt(layout.firstSymbol(block) + i);
      if (symbol == null) return null;
      _xorInto(data, symbol);
    }
    return FountainPacket(
      sessionId: sessionId,
      totalBytes: layout.totalBytes,
      symbolSize: layout.symbolSize,
      blockSymbols: layout.blockSymbols,
      block: block,
      index: index,
      data: data,
    );
  }
}

/// Rebuilds the blocks of one transfer from the packets received, in any
/// order and with any losses (Gaussian elimination over GF(2) per block).
class FountainDecoder {
  final FountainLayout layout;
  // Per block: rows keyed by their lowest set bit (the pivot)
  late final List<Map<int, _Row>> _rows = List.generate(layout.blockCount, (_) => {});
  late final List<List<Uint8List>?> _solved = List.filled(layout.blockCount, null);

  FountainDecoder(this.layout);

  bool isBlockDecoded(int block) => _solved[block] != null;

  int get decodedBlocks => _solved.where((b) => b != null).length;

  /// Symbols known so far: decoded blocks count fully, others by their rank.
  int get symbolsKnown {
    int n = 0;
    for (int b = 0; b < layout.blockCount; b++) {
      n += _solved[b] != null ? layout.symbolsInBlock(b) : _rows[b].length;
    }
    return n;
  }

  bool get isComplete => decodedBlocks == layout.blockCount;

  /// Adds a packet; returns the block index when this packet completes it.
  int? add(FountainPacket packet) {
    final block = packet.block;
    if (block >= layout.blockCount || _solved[block] != null) return null;
    final rows = _rows[block];
    int mask = layout.mask(block, packet.index);
    final data = Uint8List.fromList(packet.data);
    while (mask != 0) {
      final pivot = _lowestBit(mask);
      final row = rows[pivot];
      if (row == null) {
        rows[pivot] = _Row(mask, data);
        break;
      }
      mask ^= row.mask;
      _xorInto(data, row.data);
    }
    if (rows.length < layout.symbolsInBlock(block)) return null;
    _solve(block);
    return block;
  }

  /// Bytes of a decoded block, without the padding past the end of the key.
  Uint8List blockSymbol(int block, int i) {
    final symbol = _solved[block]![i];
    final start = (layout.firstSymbol(block) + i) * layout.symbolSize;
    final end = start + layout.symbolSize;
    return end <= layout.totalBytes ? symbol : Uint8List.sublistView(symbol, 0, layout.totalBytes - start);
  }

  void _solve(int block) {
    final rows = _rows[block];
    final k = layout.symbolsInBlock(block);
    final solved = List<Uint8List?>.filled(k, null);
    // Each row's other bits are above its pivot: solve from the top down
    for (int p = k - 1; p >= 0; p--) {
      final row = rows[p]!;
      for (int q = p + 1; q < k; q++) {
        if (row.mask & (1 << q) != 0) _xorInto(row.data, solved[q]!);
      }
      solved[p] = row.data;
    }
    _solved[block] = solved.cast<Uint8List>();
    rows.clear();
  }
}

class _Row {
  final int mask;
  final Uint8List data;
  _Row(this.mask, this.data);
}

int _lowestBit(int mask) {
  int i = 0;
  while (mask & (1 << i) == 0) {
    i++;
  }
  return i;
}

void _xorInto(Uint8List target, Uint8List source) {
  final n = source.length < target.length ? source.length : target.length;
  for (int i = 0; i < n; i++) {
    target[i] ^= source[i];
  }
}

/// Binary layout in Base45 (QR alphanumeric mode): version (1 byte, = 2),
/// session id length (1), session id (ASCII), total bytes (4), symbol size
/// (2), symbols per block (1), block (2), packet index (2), data.
class FountainCodec {
  static const _version = 2;

  const FountainCodec();

  String encode(FountainPacket p) => Base45.encode(encodeBytes(p));

  FountainPacket decode(String payload) => decodeBytes(Base45.decode(payload));

  /// The same packet without Base45, for the Bluetooth transfer.
  Uint8List encodeBytes(FountainPacket p) {
    final id = ascii.encode(p.sessionId);
    final header = ByteData(13 + id.length)
      ..setUint8(0, _version)
      ..setUint8(1, id.length);
    for (int i = 0; i < id.length; i++) {
      header.setUint8(2 + i, id[i]);
    }
    final o = 2 + id.length;
    header
      ..setUint32(o, p.totalBytes)
      ..setUint16(o + 4, p.symbolSize)
      ..setUint8(o + 6, p.blockSymbols)
      ..setUint16(o + 7, p.block)
      ..setUint16(o + 9, p.index);
    final bytes = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(p.data);
    return bytes.toBytes();
  }

  FountainPacket decodeBytes(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes.length < 13 || d.getUint8(0) != _version) throw const FormatException('Unknown packet format');
    final idLength = d.getUint8(1);
    final o = 2 + idLength;
    if (bytes.length < o + 11) throw const FormatException('Truncated packet');
    return FountainPacket(
      sessionId: ascii.decode(bytes.sublist(2, o)),
      totalBytes: d.getUint32(o),
      symbolSize: d.getUint16(o + 4),
      blockSymbols: d.getUint8(o + 6),
      block: d.getUint16(o + 7),
      index: d.getUint16(o + 9),
      data: Uint8List.fromList(bytes.sublist(o + 11)),
    );
  }
}
