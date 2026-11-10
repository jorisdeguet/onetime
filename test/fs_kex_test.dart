import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/models/firestore/fs_kex.dart';

void main() {
  test('segments round-trip through ranges', () {
    for (final segments in [
      <int>[],
      [0],
      List.generate(30720, (i) => i),
      [0, 1, 2, 5, 6, 9, 31, 32, 33],
    ]) {
      expect(FsKex.decodeSegments(FsKex.encodeSegments(segments)), segments);
    }
    expect(FsKex.encodeSegments(List.generate(30720, (i) => i)), '0-30720');
    expect(FsKex.encodeSegments([0, 1, 2, 5, 6, 9]), '0-3,5-7,9-10');
  });

  test('reads the older list format', () {
    expect(FsKex.decodeSegments([3, 1, 2]), [1, 2, 3]);
  });
}
