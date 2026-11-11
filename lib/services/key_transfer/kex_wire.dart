import 'dart:convert';
import 'dart:typed_data';

import '../../models/firestore/fs_kex.dart';

/// Message a reader sends to the source over a local link (Bluetooth).
/// Only acknowledgements and control: key bytes never travel this way.
sealed class KexReaderMessage {
  final String participantId;
  const KexReaderMessage(this.participantId);

  Map<String, dynamic> toJson();

  static KexReaderMessage fromJson(Map<String, dynamic> json) {
    final p = json['p'] as String;
    switch (json['t']) {
      case 'h':
        return KexHello(p, json['s'] as String);
      case 'a':
        return KexAck(p, FsKex.decodeSegments(json['r']));
      case 'x':
        return KexStop(p);
      case 'n':
        return KexReceived(p, json['n'] as int);
    }
    throw FormatException('Unknown reader message ${json['t']}');
  }
}

/// First message of a reader: which session it scanned.
class KexHello extends KexReaderMessage {
  final String sessionId;
  const KexHello(super.participantId, this.sessionId);
  @override
  Map<String, dynamic> toJson() => {'t': 'h', 'p': participantId, 's': sessionId};
}

/// The reader holds every segment in [segments].
class KexAck extends KexReaderMessage {
  final List<int> segments;
  const KexAck(super.participantId, this.segments);
  @override
  Map<String, dynamic> toJson() => {'t': 'a', 'p': participantId, 'r': FsKex.encodeSegments(List.of(segments)..sort())};
}

/// The reader asks the source to end the exchange (continuous mode).
class KexStop extends KexReaderMessage {
  const KexStop(super.participantId);
  @override
  Map<String, dynamic> toJson() => {'t': 'x', 'p': participantId};
}

/// Bluetooth mode: how many packets the reader received so far; the source
/// stays a few packets ahead, or the radio queue fills up and stalls the link.
class KexReceived extends KexReaderMessage {
  final int packets;
  const KexReceived(super.participantId, this.packets);
  @override
  Map<String, dynamic> toJson() => {'t': 'n', 'p': participantId, 'n': packets};
}

/// Compact encoding of the session state the source sends to its readers.
class KexWire {
  static Uint8List encodeState(FsKex s) => _utf8Json({
        'i': s.id,
        'c': s.conversationId,
        'o': s.sourceId,
        'st': s.status.name,
        'a': s.announcedSegments,
        'r': s.segmentsByPeer.map((k, v) => MapEntry(k, FsKex.encodeSegments(List.of(v)..sort()))),
        'x': s.stopRequestedBy,
      });

  static FsKex decodeState(Uint8List bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return FsKex(
      id: j['i'] as String,
      conversationId: j['c'] as String?,
      sourceId: j['o'] as String,
      segmentsByPeer: (j['r'] as Map<String, dynamic>).map((k, v) => MapEntry(k, FsKex.decodeSegments(v))),
      status: KeyExchangeStatus.values.firstWhere((e) => e.name == j['st'], orElse: () => KeyExchangeStatus.inProgress),
      announcedSegments: j['a'] as int?,
      stopRequestedBy: List<String>.from(j['x'] as List? ?? const []),
    );
  }

  static Uint8List encodeReaderMessage(KexReaderMessage m) => _utf8Json(m.toJson());

  static KexReaderMessage decodeReaderMessage(Uint8List bytes) =>
      KexReaderMessage.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);

  static Uint8List _utf8Json(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

  /// Splits a message into frames of at most [maxFrame] bytes; the first byte
  /// of each frame is 1 when more frames follow, 0 on the last one.
  static List<Uint8List> frame(Uint8List message, int maxFrame) {
    final chunk = maxFrame - 1;
    if (chunk < 1) throw ArgumentError('Frame too small: $maxFrame');
    final frames = <Uint8List>[];
    for (int o = 0; o == 0 || o < message.length; o += chunk) {
      final end = o + chunk < message.length ? o + chunk : message.length;
      frames.add(Uint8List(1 + end - o)
        ..[0] = end < message.length ? 1 : 0
        ..setRange(1, 1 + end - o, message, o));
    }
    return frames;
  }
}

/// Reassembles the frames of [KexWire.frame], one message at a time.
class KexFrameReader {
  final BytesBuilder _buffer = BytesBuilder();

  /// Returns the message once its last frame arrives, null before.
  Uint8List? add(Uint8List frame) {
    if (frame.isEmpty) return null;
    _buffer.add(Uint8List.sublistView(frame, 1));
    if (frame[0] != 0) return null;
    return _buffer.takeBytes();
  }
}

/// Union of two views of the same session (Firestore and Bluetooth): each
/// side may know acknowledgements or a completion the other does not yet.
FsKex mergeKex(FsKex a, FsKex b) {
  final peers = {...a.segmentsByPeer.keys, ...b.segmentsByPeer.keys};
  final completed = a.status == KeyExchangeStatus.completed
      ? a
      : b.status == KeyExchangeStatus.completed
          ? b
          : null;
  return FsKex(
    id: a.id,
    conversationId: a.conversationId ?? b.conversationId,
    sourceId: a.sourceId,
    segmentsByPeer: {
      for (final p in peers) p: ({...?a.segmentsByPeer[p], ...?b.segmentsByPeer[p]}.toList()..sort()),
    },
    status: completed?.status ?? a.status,
    // The count kept at the end travels with the completion; before it, the
    // latest announcement is the smaller one (it only ever shrinks)
    announcedSegments: completed?.announcedSegments ?? _min(a.announcedSegments, b.announcedSegments),
    stopRequestedBy: {...a.stopRequestedBy, ...b.stopRequestedBy}.toList(),
    startIndex: a.startIndex,
    endIndex: a.endIndex,
  );
}

int? _min(int? a, int? b) => a == null ? b : b == null ? a : (a < b ? a : b);
