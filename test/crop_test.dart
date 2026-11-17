import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sable/ui/pdf_view.dart';

/// A white page (BGRA) with a dark block of "text" in the given box.
Uint8List page(int w, int h, int l, int t, int r, int b) {
  final px = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  for (var y = t; y < b; y++) {
    for (var x = l; x < r; x++) {
      final o = (y * w + x) * 4;
      px[o] = px[o + 1] = px[o + 2] = 20;
    }
  }
  return px;
}

void main() {
  test('white borders are trimmed', () {
    final c = findPageCrop(page(160, 220, 30, 40, 130, 180), 160, 220);
    expect(c.left, closeTo(28 / 160, 0.01));
    expect(c.top, closeTo(38 / 220, 0.01));
    expect(c.right, closeTo(132 / 160, 0.01));
    expect(c.bottom, closeTo(182 / 220, 0.01));
  });

  test('at most a third is trimmed from a side', () {
    final c = findPageCrop(page(160, 220, 150, 200, 158, 218), 160, 220);
    expect(c.left, lessThanOrEqualTo(1 / 3 + 0.01));
    expect(c.top, lessThanOrEqualTo(1 / 3 + 0.01));
  });

  test('a page with no plain border is kept whole', () {
    final px = Uint8List(100 * 100 * 4)..fillRange(0, 40000, 128);
    final c = findPageCrop(px, 100, 100);
    expect(c, const Rect.fromLTRB(0, 0, 1, 1));
  });
}
