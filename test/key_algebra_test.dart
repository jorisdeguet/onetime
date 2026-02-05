import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/key_exchange/key_history.dart';
import 'package:onetime/key_exchange/key_interval.dart';

void main() {
  group('KeyInterval Algebra', () {
    const convId = 'conv_test_123';

    test('empty interval has zero length', () {
      const key = KeyInterval.empty(convId);

      expect(key.startIndex, 0);
      expect(key.endIndex, 0);
      expect(key.length, 0);
      expect(key.isEmpty, true);
      expect(key.isNotEmpty, false);
    });

    test('extension: [0,0] + [0,1024] = [0,1024]', () {
      const key = KeyInterval.empty(convId);
      const segment = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 1024,
      );

      final result = key + segment;

      expect(result.startIndex, 0);
      expect(result.endIndex, 1024);
      expect(result.length, 1024);
      expect(result.toString(), '[0, 1024)');
    });

    test('consumption: [0,1024] - [0,12] = [12,1024]', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 1024,
      );
      const segment = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 12,
      );

      final result = key - segment;

      expect(result.startIndex, 12);
      expect(result.endIndex, 1024);
      expect(result.length, 1012);
      expect(result.toString(), '[12, 1024)');
    });

    test('sequential consumption: [12,1024] - [12,14] = [14,1024]', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 12,
        endIndex: 1024,
      );
      const segment = KeyInterval(
        conversationId: convId,
        startIndex: 12,
        endIndex: 14,
      );

      final result = key - segment;

      expect(result.startIndex, 14);
      expect(result.endIndex, 1024);
      expect(result.length, 1010);
    });

    test('full scenario: create, extend, consume, consume', () {
      // t0: key = [0, 0]
      var key = const KeyInterval.empty(convId);
      expect(key.toString(), '[0, 0)');

      // t1: key = [0, 1024] via + [0, 1024] by key exchange
      final ext1 = KeyInterval(
        conversationId: convId,
        startIndex: key.endIndex,
        endIndex: 1024,
      );
      key = key + ext1;
      expect(key.toString(), '[0, 1024)');

      // t2: key = [12, 1024] via - [0, 12] by sending message
      final cons1 = key.consumeSegment(12);
      key = key - cons1;
      expect(key.toString(), '[12, 1024)');

      // t3: key = [14, 1024] via - [12, 14] by receiving message
      final cons2 = key.consumeSegment(2);
      key = key - cons2;
      expect(key.toString(), '[14, 1024)');

      expect(key.length, 1010);
    });

    test('consumeSegment creates correct interval', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 100,
        endIndex: 500,
      );

      final segment = key.consumeSegment(50);

      expect(segment.startIndex, 100);
      expect(segment.endIndex, 150);
      expect(segment.length, 50);
    });

    test('extendSegment creates correct interval', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 1024,
      );

      final segment = key.extendSegment(512);

      expect(segment.startIndex, 1024);
      expect(segment.endIndex, 1536);
      expect(segment.length, 512);
    });

    test('extension fails if segment does not start at endIndex', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 100,
      );
      const badSegment = KeyInterval(
        conversationId: convId,
        startIndex: 50, // Should be 100
        endIndex: 150,
      );

      expect(() => key + badSegment, throwsArgumentError);
    });

    test('consumption fails if segment does not start at startIndex', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 10,
        endIndex: 100,
      );
      const badSegment = KeyInterval(
        conversationId: convId,
        startIndex: 0, // Should be 10
        endIndex: 20,
      );

      expect(() => key - badSegment, throwsArgumentError);
    });

    test('consumption fails if consuming more than available', () {
      const key = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 100,
      );
      const badSegment = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 150, // More than available
      );

      expect(() => key - badSegment, throwsArgumentError);
    });

    test('operations fail across different conversations', () {
      const key1 = KeyInterval(
        conversationId: 'conv1',
        startIndex: 0,
        endIndex: 100,
      );
      const segment2 = KeyInterval(
        conversationId: 'conv2',
        startIndex: 100,
        endIndex: 200,
      );

      expect(() => key1 + segment2, throwsArgumentError);
      expect(() => key1 - segment2, throwsArgumentError);
    });

    test('equality and hashCode', () {
      const key1 = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 100,
      );
      const key2 = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 100,
      );
      const key3 = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 200,
      );

      expect(key1 == key2, true);
      expect(key1 == key3, false);
      expect(key1.hashCode == key2.hashCode, true);
    });

    test('contains check', () {
      const outer = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 100,
      );
      const inner = KeyInterval(
        conversationId: convId,
        startIndex: 10,
        endIndex: 50,
      );
      const outside = KeyInterval(
        conversationId: convId,
        startIndex: 50,
        endIndex: 150,
      );

      expect(outer.contains(inner), true);
      expect(outer.contains(outside), false);
      expect(inner.contains(outer), false);
    });

    test('overlaps check', () {
      const key1 = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 100,
      );
      const key2 = KeyInterval(
        conversationId: convId,
        startIndex: 50,
        endIndex: 150,
      );
      const key3 = KeyInterval(
        conversationId: convId,
        startIndex: 100,
        endIndex: 200,
      );

      expect(key1.overlaps(key2), true);
      expect(key1.overlaps(key3), false); // Adjacent, not overlapping
    });

    test('JSON serialization roundtrip', () {
      const original = KeyInterval(
        conversationId: convId,
        startIndex: 42,
        endIndex: 1337,
      );

      final json = original.toJson();
      final restored = KeyInterval.fromJson(json);

      expect(restored, original);
    });
  });

  group('KeyHistory', () {
    const convId = 'conv_history_test';

    test('new history starts empty', () {
      final history = KeyHistory(conversationId: convId);

      expect(history.isEmpty, true);
      expect(history.length, 0);
      expect(history.currentState, const KeyInterval.empty(convId));
    });

    test('recordExtension updates state correctly', () {
      final history = KeyHistory(conversationId: convId);

      final segment = KeyInterval(
        conversationId: convId,
        startIndex: 0,
        endIndex: 1024,
      );

      history.recordExtension(
        segment: segment,
        reason: 'kex id=kex_123',
        kexId: 'kex_123',
      );

      expect(history.length, 1);
      expect(history.currentState.startIndex, 0);
      expect(history.currentState.endIndex, 1024);
    });

    test('recordConsumption updates state correctly', () {
      final history = KeyHistory(conversationId: convId);

      // First extend
      history.recordExtension(
        segment: KeyInterval(
          conversationId: convId,
          startIndex: 0,
          endIndex: 1024,
        ),
        reason: 'kex id=kex_123',
      );

      // Then consume
      final consumeSegment = history.currentState.consumeSegment(12);
      history.recordConsumption(
        segment: consumeSegment,
        reason: 'send "hello world"',
        messageId: 'msg_456',
      );

      expect(history.length, 2);
      expect(history.currentState.startIndex, 12);
      expect(history.currentState.endIndex, 1024);
    });

    test('full scenario with formatted output', () {
      final history = KeyHistory(conversationId: convId);

      // t1: Extension via key exchange
      history.recordExtension(
        segment: KeyInterval(
          conversationId: convId,
          startIndex: 0,
          endIndex: 1024,
        ),
        reason: 'kex id=kex_123',
        kexId: 'kex_123',
      );

      // t2: Consume by sending
      var consumeSeg = history.currentState.consumeSegment(12);
      history.recordConsumption(
        segment: consumeSeg,
        reason: 'send "hello world"',
        messageId: 'msg_001',
      );

      // t3: Consume by receiving
      consumeSeg = history.currentState.consumeSegment(2);
      history.recordConsumption(
        segment: consumeSeg,
        reason: 'recv "yo"',
        messageId: 'msg_002',
      );

      final formatted = history.format();

      // Verify structure
      expect(formatted.contains('t0 : key = [0, 0)'), true);
      expect(formatted.contains('t1 : key = [0, 1024)'), true);
      expect(formatted.contains('+ [0, 1024)'), true);
      expect(formatted.contains('t2 : key = [12, 1024)'), true);
      expect(formatted.contains('- [0, 12)'), true);
      expect(formatted.contains('t3 : key = [14, 1024)'), true);
      expect(formatted.contains('- [12, 14)'), true);

      // Print for visual verification
      print('--- Key History ---');
      print(formatted);
      print('-------------------');
    });

    test('JSON serialization roundtrip', () {
      final history = KeyHistory(conversationId: convId);

      history.recordExtension(
        segment: KeyInterval(
          conversationId: convId,
          startIndex: 0,
          endIndex: 512,
        ),
        reason: 'kex id=kex_test',
        kexId: 'kex_test',
      );

      final consumeSeg = history.currentState.consumeSegment(10);
      history.recordConsumption(
        segment: consumeSeg,
        reason: 'send "test"',
        messageId: 'msg_test',
      );

      final json = history.toJson();
      final restored = KeyHistory.fromJson(json);

      expect(restored.conversationId, history.conversationId);
      expect(restored.length, history.length);
      expect(restored.currentState, history.currentState);
    });

    test('operations list is immutable from outside', () {
      final history = KeyHistory(conversationId: convId);

      history.recordExtension(
        segment: KeyInterval(
          conversationId: convId,
          startIndex: 0,
          endIndex: 100,
        ),
        reason: 'test',
      );

      final ops = history.operations;
      expect(() => ops.add(ops.first), throwsUnsupportedError);
    });
  });

  group('Real-world scenario', () {
    test('simulate conversation key lifecycle', () {
      const convId = 'conv_real_world';
      final history = KeyHistory(conversationId: convId);

      // User A and B meet and exchange key via QR codes
      history.recordExtension(
        segment: KeyInterval(
          conversationId: convId,
          startIndex: 0,
          endIndex: 65536, // 64 KB
        ),
        reason: 'kex id=kex_initial',
        kexId: 'kex_initial',
      );
      expect(history.currentState.length, 65536);

      // User A sends pseudo message
      var seg = history.currentState.consumeSegment(672);
      history.recordConsumption(
        segment: seg,
        reason: 'send pseudo "Alice"',
        messageId: 'msg_pseudo_a',
      );

      // User B sends pseudo message
      seg = history.currentState.consumeSegment(648);
      history.recordConsumption(
        segment: seg,
        reason: 'recv pseudo "Bob"',
        messageId: 'msg_pseudo_b',
      );

      // Several messages exchanged
      final messages = [
        ('send', 'Hello Bob!', 88),
        ('recv', 'Hi Alice!', 72),
        ('send', 'How are you?', 96),
        ('recv', 'Great, thanks!', 112),
      ];

      for (final (direction, content, size) in messages) {
        seg = history.currentState.consumeSegment(size);
        history.recordConsumption(
          segment: seg,
          reason: '$direction "$content"',
        );
      }

      // Key running low, do another exchange
      final extSeg = history.currentState.extendSegment(32768); // 32 KB more
      history.recordExtension(
        segment: extSeg,
        reason: 'kex id=kex_extend_1',
        kexId: 'kex_extend_1',
      );

      // Verify final state
      print('--- Real World Scenario ---');
      print(history.format());
      print('---------------------------');
      print('Final key length: ${history.currentState.length} bytes');
      print('Total operations: ${history.length}');

      expect(history.currentState.length > 0, true);
      expect(history.length, 8); // 2 extensions + 6 consumptions
    });
  });
}

